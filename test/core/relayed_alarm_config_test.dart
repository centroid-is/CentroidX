@TestOn('vm')

/// The consequence, end to end through the code an operator actually drives:
/// editing an alarm rule on a gateway panel reaches the **backend**.
///
/// `relayed_preferences_test.dart` holds the router's own routing table. This
/// file is the thing that table exists for, and it is deliberately a separate
/// arm rather than one more case there: the claim is not "a `setString` of
/// this key routes to the wire", it is "the alarm editor's own save path,
/// unchanged, now leaves this panel". Those are the same claim only for as
/// long as `RelayAlarmSource._saveConfig` keeps writing through the store it
/// was handed — which is exactly the kind of thing that gets refactored.
///
/// The bug being pinned shut: `alarm_man_config` used to be written to a
/// panel-local mirror in gateway mode, so an operator got a
/// successful-looking edit the plant never saw, and two panels held two
/// different rule sets with nothing anywhere reporting it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/relay_alarm_source.dart';
import 'package:tfc/core/relayed_preferences.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// The backend's preference store, as the wire sees it.
final class _Backend implements rp.PreferencesApi {
  final Map<String, Object?> store = {};
  final _changes = StreamController<String>.broadcast();

  @override
  Future<String?> getString(String key) async => store[key] as String?;
  @override
  Future<void> setString(String key, String value) async => store[key] = value;
  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not part of this '
          'arm — an alarm-config save must not need it');
}

/// The three things a gateway-mode alarm source needs, none of which this arm
/// is about. `ALARM.active` never fires and history is empty, so the only
/// thing that moves here is the configuration write.
final class _QuietTransport implements AlarmTransport {
  @override
  Stream<rp.DynamicValue> activeValues() => const Stream.empty();
  @override
  Future<void> ackAlarm(String alarmUid, int ruleIndex) async {}
  @override
  Future<List<rp.AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) async =>
      const [];
}

final class _NoSecrets implements MySecureStorage {
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String value}) async {}
}

void main() {
  late InMemoryPreferences mirror;
  late Preferences local;
  late _Backend backend;
  late GatewayPreferencesSlot slot;
  late RelayedPreferences prefs;

  setUp(() {
    Preferences.clearSecretCache();
    mirror = InMemoryPreferences();
    local = Preferences(
        database: null, secureStorage: _NoSecrets(), localCache: mirror);
    backend = _Backend();
    slot = GatewayPreferencesSlot();
    prefs = RelayedPreferences(
        inner: local, slot: slot, reconcileOnFill: false);
    slot.fill(backend);
  });

  tearDown(() async {
    slot.clear();
    await backend.dispose();
  });

  test('adding an alarm on a gateway panel writes the rule to the backend, '
      'and leaves no rule behind on the panel', () async {
    backend.store['alarm_man_config'] =
        jsonEncode(AlarmManConfig(alarms: []).toJson());

    final source = await RelayAlarmSource.create(
      transport: _QuietTransport(),
      preferences: prefs,
    );

    source.addAlarm(AlarmConfig(
      uid: 'CN01-jam',
      title: 'Conveyor 1 jam',
      description: 'the belt stopped with product on it',
      rules: const [],
    ));
    // `_saveConfig` is an un-awaited async body — see the class doc, which
    // names that as the remaining gap. Drain it before reading either store.
    await pumpEventQueue();

    final written = AlarmManConfig.fromJson(
        jsonDecode(backend.store['alarm_man_config']! as String));
    expect(written.alarms.map((a) => a.uid), contains('CN01-jam'),
        reason: 'the rule an operator entered must be in the plant\'s '
            'configuration, which is the whole point of this change');

    // The half that was the bug. A copy here means the panel is once again
    // holding a rule set of its own that no other panel can see.
    expect(await mirror.getString('alarm_man_config'), isNull,
        reason: 'the alarm rule must NOT have been mirrored onto this '
            'station: a local copy is how two panels come to disagree, '
            'silently, about what the plant alarms on');
  });

  test('the source reads its existing rules from the backend, not from a '
      'stale local copy', () async {
    // The station's earlier direct-mode life left a rule set behind.
    await mirror.setString(
        'alarm_man_config',
        jsonEncode(AlarmManConfig(alarms: [
          AlarmConfig(
              uid: 'STALE', title: 'deleted last week', description: 'x', rules: const []),
        ]).toJson()));
    backend.store['alarm_man_config'] = jsonEncode(AlarmManConfig(alarms: [
      AlarmConfig(uid: 'CURRENT', title: 'the plant\'s rule', description: 'x', rules: const []),
    ]).toJson());

    final source = await RelayAlarmSource.create(
      transport: _QuietTransport(),
      preferences: prefs,
    );

    expect(source.config.alarms.map((a) => a.uid), ['CURRENT'],
        reason: 'a panel that renders its own stale rules is the divergence '
            'seen from the reading side');
  });

  test('a refusal from the backend reaches the caller rather than being '
      'absorbed into a local write', () async {
    backend.store['alarm_man_config'] =
        jsonEncode(AlarmManConfig(alarms: []).toJson());
    final source = await RelayAlarmSource.create(
      transport: _QuietTransport(),
      preferences: prefs,
    );

    // The server refusing this write is the production case — the key grades
    // to `configure`, and `policy_test.dart` pins the refusal at the far end.
    // What matters here is that the panel does not answer it by writing
    // locally instead.
    slot.clear();
    slot.fail(StateError('forbidden'));

    // Captured rather than allowed to escape, because escaping is exactly
    // what it does: `_saveConfig` is an un-awaited `async` body, so a refused
    // write surfaces as an **unhandled zone error** and reaches no editor and
    // no operator. That is the residual named in `RelayAlarmSource`'s class
    // doc, and it is pinned here so that fixing it — making the three
    // mutators return futures the editor awaits — reddens this arm and gets
    // the assertion updated rather than leaving a stale claim behind.
    final escaped = <Object>[];
    await runZonedGuarded(() async {
      source.addAlarm(AlarmConfig(
          uid: 'nope',
          title: 'refused',
          description: 'x',
          rules: const []));
      await pumpEventQueue();
    }, (error, _) => escaped.add(error));

    expect(escaped, hasLength(1),
        reason: 'the refusal must not be swallowed somewhere inside the '
            'source; today it leaves as an unhandled error, which is bad but '
            'is at least not silence');
    expect(escaped.single, isA<StateError>());

    // The half that must hold either way: a refused rule is in neither store.
    expect(await mirror.getString('alarm_man_config'), isNull,
        reason: 'a write the backend refused must not be consoled with a '
            'local copy — that is precisely how the panel would start '
            'running rules the plant never accepted');
    expect(backend.store['alarm_man_config'],
        jsonEncode(AlarmManConfig(alarms: []).toJson()));
  });
}
