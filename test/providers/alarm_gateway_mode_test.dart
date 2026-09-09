/// Gateway mode does not evaluate alarms, and acknowledging still works.
///
/// **The two pins D-10 asks for, because one is not enough.** A runtime type
/// assertion says the provider resolved a [RelayAlarmSource] *today*; a
/// comment-stripped source scan says nobody put `AlarmMan.create` back on the
/// gateway branch as a "temporary" fallback. Neither implies the other: a
/// fallback that only fires when the transport is unavailable passes the type
/// arm on the happy path, and a source scan cannot see a wiring mistake that
/// leaves the branch textually correct.
///
/// **Why this matters on a plant, measured.** The rig's `alarm_man_config`
/// contains a rule on `__agg_default_connected == false`, and nothing in this
/// repository produces `__agg_default_connected`. In gateway mode
/// `GatewayStateMan.connMetaAliases` is `const []` and `subscribeConnMeta`
/// throws by name, so that variable is unbound, coerces to `false`, and the
/// alarm fires permanently on a healthy plant. Retiring panel-side evaluation
/// is what fixes it — which is why arm 3 counts subscriptions rather than
/// trusting a comment.
///
/// **This file proves the panel's half of the acknowledge and nothing more.**
/// That an ack actually reaches the backend and the alarm actually leaves
/// `ALARM.active` over a real socket is 14-14's measured arm; that a `view`
/// session's ack is refused is 14-12's. No backend is stood up here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' as ua;
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/core/relay_alarm_source.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/alarm.dart' show ViewActiveAlarm;
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart'
    show AppDatabase, AlarmHistoryCompanion;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show AlarmAckUnsupported;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

import '../helpers/test_helpers.dart' show FakeSecureStorage;

// ---------------------------------------------------------------- fixtures

/// The instant the backend says the stop started. Hours away from any clock a
/// test machine holds, so an implementation that stamps locally cannot agree
/// by accident.
final backendOnset = DateTime.utc(2026, 9, 6, 12, 0, 0, 123);

/// An alarm the panel's own `alarm_man_config` knows about.
///
/// Its rule order is deliberately the REVERSE of the rule index the payload
/// carries, so an implementation that recomputes the index from the local
/// config sends a different number (arm 7 / sabotage (i)).
AlarmConfig knownAlarm() => AlarmConfig(
      uid: 'CN04.MOT01',
      title: 'Local title, one restart behind',
      description: 'Local description',
      rules: [
        AlarmRule(
          level: AlarmLevel.info,
          expression: ExpressionConfig(value: Expression(formula: 'a > 1')),
          acknowledgeRequired: false,
        ),
        AlarmRule(
          level: AlarmLevel.error,
          expression: ExpressionConfig(value: Expression(formula: 'b > 2')),
          acknowledgeRequired: true,
        ),
      ],
    );

/// A second configured alarm, so arm 3 has more than one rule set that a
/// panel-side evaluator would have to subscribe for.
AlarmConfig secondAlarm() => AlarmConfig(
      uid: 'CN05.MOT01',
      title: 'Second',
      description: 'Second',
      rules: [
        AlarmRule(
          level: AlarmLevel.warning,
          expression:
              ExpressionConfig(value: Expression(formula: 'c > 3 AND d < 4')),
          acknowledgeRequired: false,
        ),
      ],
    );

rp.AlarmActiveEntry entry({
  String uid = 'CN04.MOT01',
  int ruleIndex = 0,
  String level = 'error',
  String title = 'Motor overload',
  String description = 'the drive tripped',
  List<String> group = const ['Line 3'],
  String? expression = 'a{10.0} > 5',
  int? activeAtMs,
  String tsSource = rp.AlarmActiveEntry.tsSourcePlant,
  bool pendingAck = false,
  List<String> staleInputs = const [],
  int? staleSinceMs,
}) =>
    rp.AlarmActiveEntry(
      uid: uid,
      ruleIndex: ruleIndex,
      level: level,
      title: title,
      description: description,
      group: group,
      expression: expression,
      activeAtMs: activeAtMs ?? backendOnset.millisecondsSinceEpoch,
      tsSource: tsSource,
      pendingAck: pendingAck,
      staleInputs: staleInputs,
      staleSinceMs: staleSinceMs,
    );

/// One `alarm_history` row as the backend puts it on the wire.
///
/// Deliberately titled and levelled DIFFERENTLY from [knownAlarm], so a source
/// that resolved the row against the panel's own configuration — the way
/// `AlarmMan.getRecentAlarms` does on a direct station — produces observably
/// different output rather than the same output by luck.
rp.AlarmHistoryEntry historyRow({
  String uid = 'CN04.MOT01',
  int? ruleIndex = 1,
  String level = 'error',
  String title = 'Motor overload',
  String description = 'the drive tripped',
  List<String> group = const ['Line 3'],
  String? expression = 'a{10.0} > 5',
  bool acknowledgeRequired = false,
  bool active = false,
  bool pendingAck = false,
  DateTime? createdAt,
  DateTime? deactivatedAt,
  String? tsSource = rp.AlarmActiveEntry.tsSourcePlant,
}) =>
    rp.AlarmHistoryEntry(
      uid: uid,
      ruleIndex: ruleIndex,
      level: level,
      title: title,
      description: description,
      group: group,
      expression: expression,
      acknowledgeRequired: acknowledgeRequired,
      active: active,
      pendingAck: pendingAck,
      createdAt: createdAt ?? backendOnset,
      deactivatedAt: active
          ? null
          : (deactivatedAt ?? backendOnset.add(const Duration(minutes: 4))),
      tsSource: tsSource,
    );

// ------------------------------------------------------------------- fakes

/// The gateway's own refusal, as this file needs to observe it.
///
/// The production type is `json_rpc_2`'s `RpcException`, which
/// `tfc_relay_client` deliberately does **not** re-export — only
/// [AlarmAckUnsupported] crosses that barrel
/// (`tfc_relay_client.dart:61`). The property under test here is that
/// `RelayAlarmSource` does not catch, and the exact class of what it declines
/// to catch is 14-13's business; pinning it here would only re-test that
/// package. [AlarmAckUnsupported] itself is exercised by arm 11c, which is the
/// one type an app-side caller can name.
class _GatewayRefusal implements Exception {
  const _GatewayRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Stands in for `LinkDown('ackAlarm')` — same reason: `deadline.dart` is not
/// exported either.
class _LinkDown implements Exception {
  const _LinkDown(this.method);
  final String method;
  @override
  String toString() =>
      'LinkDown: no connection to the gateway when calling "$method"';
}

/// The relay client's alarm port, recorded rather than dialled.
///
/// A double for `RemoteStateMan` itself is impossible — it is a `final class`,
/// so nothing outside its own library may implement it. That is exactly why
/// [AlarmTransport] exists as a three-member port: the active-set stream, the
/// acknowledge, and — since history stopped being readable from a database a
/// gateway panel no longer has — the history read.
class _RecordingTransport implements AlarmTransport {
  final List<String> subscribed = <String>[];
  final List<({String uid, int ruleIndex})> acks =
      <({String uid, int ruleIndex})>[];

  final StreamController<rp.DynamicValue> _values =
      StreamController<rp.DynamicValue>.broadcast();

  /// Set to make the next (and every subsequent) acknowledge throw.
  Object? ackError;

  /// Set to hold the acknowledge open, so an arm can look at the world while
  /// the RPC is in flight.
  Completer<void>? ackGate;

  /// Whether anything is still listening to `ALARM.active` through this port.
  ///
  /// The observable half of "the old source was closed": a flag on the source
  /// would only say that `close()` ran, and what CR-01 is about is whether the
  /// **subscription** on a dead client was actually let go.
  bool get hasListener => _values.hasListener;

  @override
  Stream<rp.DynamicValue> activeValues() {
    subscribed.add(rp.AlarmKeys.active);
    return _values.stream;
  }

  @override
  Future<void> ackAlarm(String alarmUid, int ruleIndex) async {
    acks.add((uid: alarmUid, ruleIndex: ruleIndex));
    final gate = ackGate;
    if (gate != null) await gate.future;
    final error = ackError;
    if (error != null) throw error;
  }

  /// Every history window this port was asked for, in order.
  final List<({int limit, DateTime? from, DateTime? to})> historyQueries =
      <({int limit, DateTime? from, DateTime? to})>[];

  /// What the backend holds. Empty by default, which is a *fact* about the
  /// plant here and never a stand-in for a failure — [historyError] is how an
  /// arm models the gateway declining.
  List<rp.AlarmHistoryEntry> historyRows = const [];

  /// Set to make the next (and every subsequent) history read throw.
  Object? historyError;

  @override
  Future<List<rp.AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) async {
    historyQueries.add((limit: limit, from: from, to: to));
    final error = historyError;
    if (error != null) throw error;
    return historyRows;
  }

  void push(
    List<rp.AlarmActiveEntry> entries, {
    bool truncated = false,
    int omitted = 0,
  }) =>
      _values.add(rp.DynamicValue(
          value: rp.AlarmActiveEntry.encodeList(entries,
              truncated: truncated, omitted: omitted)));

  Future<void> close() => _values.close();
}

/// A `StateMan` that records every subscription and refuses everything else.
///
/// Arm 3's whole point: in gateway mode the alarm source must ask this object
/// for **nothing**. A permissive stub would let the arm pass while the panel
/// quietly re-subscribed every rule variable.
final class _RecordingStateMan implements StateMan {
  final List<String> subscribed = <String>[];

  @override
  Future<Stream<ua.DynamicValue>> subscribe(String key) async {
    subscribed.add(key);
    return const Stream<ua.DynamicValue>.empty();
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'the alarm source reached the StateMan (${invocation.memberName})');
}

class _MemoryDb extends AppDatabase {
  _MemoryDb() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

// -------------------------------------------------------------- containers

Future<Preferences> _prefs({
  required List<AlarmConfig> alarms,
  Database? database,
}) async {
  Preferences.clearSecretCache();
  final preferences =
      Preferences(database: database, secureStorage: FakeSecureStorage());
  await preferences.setString(
      'alarm_man_config', jsonEncode(AlarmManConfig(alarms: alarms).toJson()),
      saveToDb: false);
  return preferences;
}

ProviderContainer _container({
  required bool gateway,
  required Preferences preferences,
  AlarmTransport? transport,
  StateMan? stateMan,
}) {
  final container = ProviderContainer(overrides: [
    gatewayConfigProvider.overrideWith((ref) async => gateway
        ? const GatewayConfig(
            mode: TransportMode.gateway,
            url: 'wss://gateway.svn:9443',
            caCertPath: '/etc/tfc/ca.pem')
        : const GatewayConfig()),
    preferencesProvider.overrideWith((ref) async => preferences),
    stateManProvider
        .overrideWith((ref) async => stateMan ?? _RecordingStateMan()),
    gatewayAlarmSlotProvider
        .overrideWith((ref) => GatewayAlarmSlot()..transport = transport),
  ]);
  addTearDown(container.dispose);
  return container;
}

// --------------------------------------------------------------- utilities

/// [source] with `//` line comments and `/* */` block comments removed.
///
/// The shape `pipe_shutdown_structure_test.dart` uses. Comments are stripped
/// because the scanned file documents at length WHY panel-side evaluation is
/// gone, and prose that names `AlarmMan.create` or `Evaluator` would make the
/// gate worthless.
String _stripComments(String source) {
  final out = StringBuffer();
  var inBlock = false;
  for (final rawLine in source.split('\n')) {
    var line = rawLine;
    if (inBlock) {
      final end = line.indexOf('*/');
      if (end < 0) continue;
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    final comment = _lineCommentAt(line);
    if (comment >= 0) line = line.substring(0, comment);
    out.writeln(line);
  }
  return out.toString();
}

int _lineCommentAt(String line) {
  var singles = 0;
  var doubles = 0;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'") singles++;
    if (c == '"') doubles++;
    if (c == '/' && line[i + 1] == '/' && singles.isEven && doubles.isEven) {
      return i;
    }
  }
  return -1;
}

/// The brace-matched block that follows [anchor], or `''` when absent.
String _blockAfter(String source, String anchor) {
  final start = source.indexOf(anchor);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}

/// One cleared-but-unacknowledged alarm, exactly as [RelayAlarmSource] builds
/// it out of an `ALARM.active` entry with `pendingAck: true`.
///
/// Spelled by hand in the widget arms rather than driven through the source's
/// stream, because `testWidgets` runs under `FakeAsync`: a bare
/// `Future.delayed(Duration.zero)` inside one never completes without a pump,
/// and the arms below are about the CONTROL, not about the decode (arms 5-8
/// cover that against the real object).
AlarmActive _pendingAckAlarm() => AlarmActive(
      alarm: Alarm(config: knownAlarm()),
      notification: AlarmNotification(
        uid: 'CN04.MOT01',
        active: false,
        expression: 'b{3} > 2',
        rule: knownAlarm().rules[1],
        timestamp: backendOnset,
        ruleIndex: 1,
      ),
      pendingAck: true,
    );

/// The whole statement beginning at [anchor], up to its terminating `;`.
///
/// Empty when [anchor] is absent, which reads as "the thing is not there" in
/// every arm that uses it.
String _statementAt(String source, String anchor) {
  final start = source.indexOf(anchor);
  if (start < 0) return '';
  final end = source.indexOf(';', start);
  return end < 0 ? source.substring(start) : source.substring(start, end + 1);
}

/// A container wired the way production wires gateway mode, so that
/// `stateManProvider` can be invalidated and the slot moves with it.
///
/// `_container` above fixes one transport for the life of the container, which
/// is exactly the case CR-01 is NOT about. Here every build of
/// `stateManProvider` takes the next transport out of [transports] and
/// publishes it into the slot, and clears the slot on dispose — which is what
/// `state_man.dart:182` and `:204` do around the real `GatewayStateMan`.
ProviderContainer _reloadableGatewayContainer({
  required Preferences preferences,
  required List<_RecordingTransport> transports,
}) {
  final slot = GatewayAlarmSlot();
  var builds = 0;
  final container = ProviderContainer(overrides: [
    gatewayConfigProvider.overrideWith((ref) async => const GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://gateway.svn:9443',
        caCertPath: '/etc/tfc/ca.pem')),
    preferencesProvider.overrideWith((ref) async => preferences),
    gatewayAlarmSlotProvider.overrideWith((ref) => slot),
    stateManProvider.overrideWith((ref) async {
      final transport = transports[builds++];
      slot.transport = transport;
      ref.onDispose(() => slot.transport = null);
      return _RecordingStateMan();
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// The active set as the widgets would see it, after [pumps] microtask turns.
Future<Set<AlarmActive>> _settle(AlarmSource source, {int pumps = 8}) async {
  Set<AlarmActive> latest = const {};
  final sub = source.activeAlarms().listen((set) => latest = set);
  for (var i = 0; i < pumps; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await sub.cancel();
  return latest;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the provider branches on the transport (D-10, pin 1 of 2)', () {
    // ------------------------------------------------------------------ 1
    test('gateway mode resolves a RelayAlarmSource', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      expect(source, isA<RelayAlarmSource>(),
          reason: 'a gateway-mode panel is TOLD the active set; it must not '
              'construct an object whose job is to compute one');
    });

    // ------------------------------------------------------------------ 2
    test('direct mode still resolves an AlarmMan', () async {
      final container = _container(
        gateway: false,
        preferences: await _prefs(alarms: [knownAlarm()]),
      );

      final source = await container.read(alarmManProvider.future);
      expect(source, isA<AlarmMan>(),
          reason: 'the split is a branch, not a replacement — the plant runs '
              'direct mode today and nothing about it changes');
      expect(source, isNot(isA<RelayAlarmSource>()));
    });

    // ------------------------------------------------------------------ 3
    test('no rule variable is subscribed on the alarm source\'s behalf',
        () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final stateMan = _RecordingStateMan();
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm(), secondAlarm()]),
        transport: transport,
        stateMan: stateMan,
      );

      final source = await container.read(alarmManProvider.future);
      await _settle(source);

      expect(transport.subscribed, [rp.AlarmKeys.active],
          reason: 'one subscription, and it is the backend\'s own answer');
      expect(stateMan.subscribed, isEmpty,
          reason: 'today the panel subscribes every variable of every rule — '
              'including `__agg_default_connected`, which nothing produces, '
              'so the rule reading it fires forever on a healthy plant');
    });
  });

  group('the empty-config seed is a direct-mode thing only', () {
    // The seed exists so that a never-configured station does not have
    // `AlarmMan.create` write a `configure` key at boot with nobody signed
    // in. On the relay the shared store is the BACKEND's, so the same line
    // would be this panel writing an empty alarm config into the plant —
    // racing every other panel that booted at the same time, and refused by
    // the server's `configure` gate for a station that lacks the group, which
    // would error this provider and take the alarm surface down at boot.

    /// A store with no `alarm_man_config` at all, which is the only state in
    /// which the seed fires. [_prefs] always pre-seeds it, which is why no
    /// existing arm in this file reaches the branch.
    Future<Preferences> unconfigured() async {
      Preferences.clearSecretCache();
      return Preferences(database: null, secureStorage: FakeSecureStorage());
    }

    test('a gateway panel with no alarm config writes none', () async {
      final preferences = await unconfigured();
      final container = _container(
        gateway: true,
        preferences: preferences,
        transport: _RecordingTransport(),
      );

      await container.read(alarmManProvider.future);

      expect(await preferences.getString('alarm_man_config'), isNull,
          reason: 'the panel seeded the plant\'s alarm configuration. On this '
              'transport that key is the backend\'s, and an empty config '
              'written over it is every alarm rule in the factory gone');
    });

    test('and the source still comes up, reading the absence as no rules yet',
        () async {
      // Anti-vacuity for the arm above in the direction that matters: not
      // writing must not mean not working. If the seed were load-bearing this
      // would fail rather than pass silently.
      final container = _container(
        gateway: true,
        preferences: await unconfigured(),
        transport: _RecordingTransport(),
      );

      final man = await container.read(alarmManProvider.future);
      expect(man.config.alarms, isEmpty);
    });

    test('and the store it was handed is genuinely writable — the arm above '
        'is not passing against an inert double', () async {
      final preferences = await unconfigured();
      final container = _container(
        gateway: true,
        preferences: preferences,
        transport: _RecordingTransport(),
      );
      await container.read(alarmManProvider.future);

      await preferences.setString('alarm_man_config', 'x', saveToDb: false);
      expect(await preferences.getString('alarm_man_config'), 'x');
    });
  });

  group('panel-side evaluation is structurally absent (D-10, pin 2 of 2)', () {
    // ------------------------------------------------------------------ 4
    test('the gateway branch names no AlarmMan.create and no Evaluator', () {
      final source =
          _stripComments(File('lib/providers/alarm.dart').readAsStringSync());

      // Anchored on the branch's own opening, not on the bare identifier:
      // `alarmManProvider` also tests the transport to skip the direct-mode
      // `alarm_man_config` seed, and a bare-identifier anchor would find that
      // guard's block instead and pass or fail on the wrong code. The arm
      // below still fails closed if this anchor ever stops matching.
      final branch = _blockAfter(source, 'if (gateway.isGateway) {');
      expect(branch, isNotEmpty,
          reason: 'the roster must fail CLOSED: an arm that cannot find the '
              'branch it is scanning proves nothing at all');
      expect(branch, contains('RelayAlarmSource'),
          reason: 'the branch this arm found must be the one that matters');
      expect(branch, isNot(contains('AlarmMan.create')),
          reason: 'a silent fallback to AlarmMan is how panel-side '
              'evaluation comes back (T-14-39)');

      expect('AlarmMan.create'.allMatches(source), hasLength(1),
          reason: 'exactly one construction site, on the direct branch');
      expect(source, isNot(contains('Evaluator')));
    });

    // ------------------------------------------------------------------ 4b
    test('RelayAlarmSource itself names no Evaluator and refuses nothing', () {
      final source = _stripComments(
          File('lib/core/relay_alarm_source.dart').readAsStringSync());
      expect(source, isNotEmpty);
      expect(source, contains('class RelayAlarmSource'));
      expect(source, isNot(contains('Evaluator')));
      expect(source, isNot(contains('UnsupportedError')),
          reason: 'Q-1 as ruled: the acknowledge is relayed, not refused by '
              'name. The only refusal left in the solve is the provider\'s '
              'not-a-gateway-client case');
    });

    // ------------------------------------------------------------------ 4c
    test('the widget knows nothing about the transport', () {
      final source =
          _stripComments(File('lib/widgets/alarm.dart').readAsStringSync());
      expect(source, isNotEmpty);
      expect(source, isNot(contains('RelayAlarmSource')));
      expect(source, isNot(contains('GatewayStateMan')));
    });
  });

  group('the active set is the backend\'s, timestamps included', () {
    // ------------------------------------------------------------------ 5
    test('activeAtMs arrives as exactly that instant, in UTC', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([entry()]);
      final active = await _settle(source);

      expect(active, hasLength(1));
      final only = active.single;
      expect(only.notification.timestamp, backendOnset,
          reason: 'exactly, not close to: two panels in two time zones must '
              'not disagree about when the line stopped');
      expect(only.notification.timestamp.isUtc, isTrue);
      expect(only.notification.tsSource, AlarmTsSource.plant,
          reason: 'the payload said the plant supplied the instant');
    });

    // ----------------------------------------------------------------- 5b
    test('the backend\'s hold badge survives the conversion the widgets read',
        () async {
      // The rig defect this closes (2026-09-08): "Cooler temperature" held
      // true by D-3 on a dead cooler.temp.avg, and the panel had nowhere to
      // even put the fact. The payload now carries it; losing it in
      // `_activeOf` would re-blind every gateway station.
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      final heldSince = backendOnset.add(const Duration(seconds: 12));
      transport.push([
        entry(
          staleInputs: const ['cooler.temp.avg'],
          staleSinceMs: heldSince.millisecondsSinceEpoch,
        ),
      ]);
      final active = await _settle(source);

      final only = active.single;
      expect(only.notification.staleInputs, ['cooler.temp.avg'],
          reason: 'the operator\'s next act is to check this sensor by name');
      expect(only.notification.staleSince, heldSince);
      expect(only.notification.staleSince!.isUtc, isTrue);

      // And a live entry states its liveness.
      transport.push([entry()]);
      final live = await _settle(source);
      expect(live.single.notification.staleInputs, isEmpty);
      expect(live.single.notification.staleSince, isNull);
    });

    // ------------------------------------------------------------------ 6
    test('an entry the local config has never heard of still renders',
        () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        // The panel is one restart behind: it knows only the second alarm.
        preferences: await _prefs(alarms: [secondAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([
        entry(
            uid: 'CN99.NEW01',
            title: 'Brand new alarm',
            description: 'configured after this panel booted',
            level: 'warning'),
      ]);
      final active = await _settle(source);

      expect(active, hasLength(1),
          reason: 'a panel one restart behind must not drop an alarm it '
              'cannot find in its own configuration');
      final only = active.single;
      expect(only.alarm.config.title, 'Brand new alarm');
      expect(only.alarm.config.description, 'configured after this panel '
          'booted');
      expect(only.notification.rule.level, AlarmLevel.warning);
    });

    // ------------------------------------------------------------------ 5b
    //
    // **Found by sabotage, 2026-09-09.** Arm 5 above covers a uid the local
    // config has never heard of, so a `_activeOf` that preferred the local
    // title falls straight through to the payload's and the arm stays green.
    // Mutating `title: entry.title` to a lookup in `alarms` survived the whole
    // suite. [knownAlarm]'s title is spelled 'Local title, one restart behind'
    // for exactly this arm — the fixture was built for it and the arm was
    // never written.
    test('a KNOWN entry still renders the backend\'s words, not the local ones',
        () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        // The panel knows this uid, and knows it by a different name.
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([
        entry(
            uid: 'CN04.MOT01',
            title: 'Motor overload',
            description: 'the drive tripped',
            level: 'error'),
      ]);
      final active = await _settle(source);

      final only = active.single;
      expect(only.alarm.config.title, 'Motor overload',
          reason: 'the two copies are not the same age: preferences are '
              're-read on a restart, so a panel that has been up since before '
              'the last configuration change would otherwise draw a live '
              'alarm under a name nobody in the plant uses any more');
      expect(only.alarm.config.description, 'the drive tripped');
      expect(only.alarm.config.title,
          isNot(equals(knownAlarm().title)),
          reason: 'stated as a contrast so the arm cannot pass by the two '
              'titles happening to agree');
    });

    // ------------------------------------------------------------------ 6b
    test('a truncated list is reported rather than presented as complete',
        () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source =
          await container.read(alarmManProvider.future) as RelayAlarmSource;
      await Future<void>.delayed(Duration.zero);
      transport.push([entry()], truncated: true, omitted: 41);
      await _settle(source);

      expect(source.activeTruncated, isTrue);
      expect(source.activeOmitted, 41);
    });
  });

  group('acknowledging crosses the pipe (Q-1 as ruled, 2026-09-06)', () {
    // ------------------------------------------------------------------ 7
    test('ackAlarm sends the payload\'s (uid, ruleIndex)', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      // The payload says rule 1. The local config's rules are in the other
      // order, so an implementation that resolves the index locally sends 0.
      transport.push([entry(ruleIndex: 1, pendingAck: true)]);
      final active = await _settle(source);

      await source.ackAlarm(active.single);

      expect(transport.acks, hasLength(1));
      expect(transport.acks.single.uid, 'CN04.MOT01');
      expect(transport.acks.single.ruleIndex, 1,
          reason: 'the identity is the payload\'s. A panel one restart behind '
              'that recomputed the index would acknowledge the wrong rule of '
              'the right alarm — a silent mis-actuation of the operator\'s '
              'intent');
    });

    // ------------------------------------------------------------------ 8
    test('it does not remove locally, in flight or after success', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final gate = Completer<void>();
      transport.ackGate = gate;
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([entry(ruleIndex: 1, pendingAck: true)]);
      final active = await _settle(source);
      expect(active, hasLength(1));

      final inFlight = source.ackAlarm(active.single);
      expect(await _settle(source), hasLength(1),
          reason: 'while the RPC is in flight the backend still says the '
              'alarm is active, and the screen must say what the backend says');

      gate.complete();
      await inFlight;
      expect(await _settle(source), hasLength(1),
          reason: 'a local removal is undone by the next ALARM.active, and an '
              'operator who watched an alarm vanish and reappear learns to '
              'distrust the screen');

      transport.push(const []);
      expect(await _settle(source), isEmpty,
          reason: 'the confirmation is the readback, and only the readback');
    });

    // ------------------------------------------------------------------ 9
    test('a refusal surfaces with the gateway\'s own words', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      transport.ackError =
          const _GatewayRefusal('this station has no operate role');
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([entry(ruleIndex: 1, pendingAck: true)]);
      final active = await _settle(source);

      await expectLater(
        source.ackAlarm(active.single),
        throwsA(isA<_GatewayRefusal>().having(
            (e) => e.message, 'message', contains('no operate role'))),
      );
      expect(await _settle(source), hasLength(1),
          reason: 'a refused acknowledge changes nothing');
    });

    // ----------------------------------------------------------------- 10
    test('a link-down acknowledge is never retried', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      transport.ackError = const _LinkDown('ackAlarm');
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);
      transport.push([entry(ruleIndex: 1, pendingAck: true)]);
      final active = await _settle(source);

      await expectLater(
          source.ackAlarm(active.single), throwsA(isA<_LinkDown>()));
      // A generous margin: a retry with any backoff at all lands inside it.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _settle(source);
      expect(transport.acks, hasLength(1),
          reason: 'phase law: an acknowledge is sent once or not at all');
    });
  });

  group('the acknowledge control (Q-1 as ruled: enabled in both modes)', () {
    Future<void> pump(WidgetTester tester, ProviderContainer container,
        AlarmActive alarm) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: ViewActiveAlarm(alarm: alarm)),
        ),
      ));
      // Settled before the button is read, so an implementation that decided
      // the control's state from an ASYNC provider — which is what the
      // superseded "disabled in gateway mode" interim would have had to do —
      // has had its answer arrive. Without this the arm would read the frame
      // where every FutureProvider is still `null` and call a disabled button
      // enabled.
      await tester.pumpAndSettle();
    }

    // ----------------------------------------------------------------- 11
    testWidgets('the button is drawn and enabled in gateway mode',
        (tester) async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );
      await pump(tester, container, _pendingAckAlarm());

      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Acknowledge'));
      expect(button.onPressed, isNotNull,
          reason: 'the transport is not a reason to hide an operator action');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Acknowledge'));
      await tester.pumpAndSettle();
      expect(transport.acks, hasLength(1),
          reason: 'the press must reach the pipe, not a local set');
      expect(find.text('Alarm acknowledged'), findsOneWidget);
    });

    // ---------------------------------------------------------------- 11b
    testWidgets('the button is drawn and enabled in direct mode too',
        (tester) async {
      final container = _container(
        gateway: false,
        preferences: await _prefs(alarms: [knownAlarm()]),
      );
      await pump(tester, container, _pendingAckAlarm());

      final button = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Acknowledge'));
      expect(button.onPressed, isNotNull,
          reason: 'the pair says: the transport does not change what an '
              'operator may do');
    });

    // ---------------------------------------------------------------- 11c
    testWidgets('a refused acknowledge is shown, and the card does not close',
        (tester) async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      // The one production failure type an app-side caller can name, so this
      // arm proves 14-13's barrel export is usable from here.
      transport.ackError = AlarmAckUnsupported(
          'alarm.ack', 'no such method on this gateway');
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );
      var closed = false;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ViewActiveAlarm(
                alarm: _pendingAckAlarm(), onClose: () => closed = true),
          ),
        ),
      ));

      await tester.tap(find.widgetWithText(ElevatedButton, 'Acknowledge'));
      await tester.pumpAndSettle();

      expect(find.textContaining('predates'), findsOneWidget,
          reason: 'a refusal the operator cannot see is the silent loss this '
              'project exists to prevent');
      expect(find.text('Alarm acknowledged'), findsNothing);
      expect(closed, isFalse,
          reason: 'a card that closes on a failed acknowledge is a card that '
              'told the operator it worked');
    });
  });

  // D-11 had two halves. The **history** half is superseded — a gateway panel
  // has no database, so `getRecentAlarms` reads the backend now; see arm 12.
  // The **configuration** half stands: the alarm editor still writes
  // `alarm_man_config` through preferences, and a gateway station whose editor
  // was silently read-only would be a worse bug than the one it fixes.
  group('what a gateway-mode panel still does, and where it now asks', () {
    late AppDatabase appDb;
    late Database database;

    setUp(() {
      appDb = _MemoryDb();
      database = Database(appDb);
    });

    tearDown(() async {
      await database.dispose();
      await appDb.close();
    });

    // ---------------------------------------------------------------- 12
    //
    // **D-11 is superseded, and this arm records why.** The ruling said
    // history stays local because *"the panel holds its own Postgres
    // connection in gateway mode — preferencesProvider builds it
    // unconditionally"*. That premise is now false:
    // `lib/providers/preferences.dart:60` branches on the transport before it
    // reads the config row, so in gateway mode `Preferences` is built with
    // `db: null` and `if (preferences.database == null) return []` was the
    // ONLY branch `getRecentAlarms` ever took. No error, no log line — a
    // history page that looks like a factory which has never had an alarm.
    //
    // The arm below is deliberately hostile: the panel is handed a database
    // holding a row it *would* have returned under D-11, and the transport is
    // handed a different one. A source that reads the database passes nothing
    // here, and a source that reads neither is caught by the count.
    test('getRecentAlarms reads the backend, not the panel\'s own database',
        () async {
      await appDb.into(appDb.alarmHistory).insert(
            AlarmHistoryCompanion.insert(
              alarmUid: 'CN04.MOT01',
              alarmTitle: 'A local row nobody should ever see',
              alarmDescription: 'written straight into the panel\'s database',
              alarmLevel: 'error',
              expression: const Value('a{10.0} > 5'),
              active: false,
              pendingAck: false,
              createdAt: backendOnset,
              deactivatedAt: Value(backendOnset.add(const Duration(minutes: 4))),
              ruleIndex: const Value(1),
              tsSource: const Value('plant'),
            ),
          );

      final transport = _RecordingTransport()
        ..historyRows = [historyRow(title: 'The backend\'s row')];
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences:
            await _prefs(alarms: [knownAlarm()], database: database),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      final rows = await source.getRecentAlarms();

      expect(rows, hasLength(1));
      expect(rows.single.alarm.config.title, 'The backend\'s row',
          reason: 'the backend is the process that has alarm_history; a '
              'gateway panel has no database at all, so a read that went to '
              'one could only ever answer empty');
      expect(transport.historyQueries, hasLength(2),
          reason: 'two reads, both over the wire: `create` primes the history '
              'stream and this arm asked again. A source still reading the '
              'database would show none at all');
    });

    // --------------------------------------------------------------- 12b
    test('the window and the limit go to the backend unchanged', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      transport.historyQueries.clear();

      await source.getRecentAlarms(
        limit: 2000,
        from: DateTime.utc(2026, 9, 1, 6),
        to: DateTime.utc(2026, 9, 1, 14),
      );

      // `AlarmMan.getRecentAlarms`'s three arguments, arriving intact. A
      // transport that dropped the window would answer the newest N rows to a
      // stop timeline asking about last Tuesday — confidently wrong rather
      // than empty, which is worse.
      expect(transport.historyQueries, [
        (
          limit: 2000,
          from: DateTime.utc(2026, 9, 1, 6),
          to: DateTime.utc(2026, 9, 1, 14)
        )
      ]);
    });

    // --------------------------------------------------------------- 12c
    test('a history row is read off the payload, never joined against the '
        'local config', () async {
      // `AlarmMan.getRecentAlarms` resolves each row against the local
      // configuration and returns null — dropped by `whereType`, silently —
      // for a uid it cannot find. Across this wire the two copies are a
      // backend that evaluated the rules and a panel holding a device-local
      // mirror, so that join would make an alarm renamed last week erase its
      // own history with no error anywhere.
      final transport = _RecordingTransport()
        ..historyRows = [
          historyRow(
            uid: 'CN99.NOBODY-HERE-KNOWS-THIS',
            title: 'Renamed since this panel last synced',
            level: 'warning',
            acknowledgeRequired: true,
          )
        ];
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      final rows = await source.getRecentAlarms();

      expect(rows, hasLength(1),
          reason: 'a row for an alarm this panel\'s config has never heard of '
              'is still a thing that happened on the plant');
      expect(rows.single.alarm.config.title,
          'Renamed since this panel last synced');
      expect(rows.single.notification.rule.level, AlarmLevel.warning);
      expect(rows.single.notification.rule.acknowledgeRequired, isTrue,
          reason: 'resolved by the backend against the configuration its '
              'engine actually ran, and carried on the row — the panel does '
              'not index into its own rule list to find it');
    });

    // --------------------------------------------------------------- 12d
    test('a still-standing row keeps a null deactivation', () async {
      // Null is what makes a row overlap every window it started before, which
      // is what `alarmHistoryOverlaps` and `StopIntervalSource` are built on.
      final transport = _RecordingTransport()
        ..historyRows = [historyRow(active: true, deactivatedAt: null)];
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      final rows = await source.getRecentAlarms();

      expect(rows.single.deactivated, isNull);
      expect(rows.single.notification.active, isTrue);
      expect(rows.single.notification.timestamp, backendOnset,
          reason: 'the backend\'s instant, in UTC, to the millisecond — never '
              'reconstructed through this machine\'s time zone');
      expect(rows.single.notification.timestamp.isUtc, isTrue);
    });

    // --------------------------------------------------------------- 12e
    test('a pre-v7 row states no rule and the panel does not guess one',
        () async {
      final transport = _RecordingTransport()
        ..historyRows = [historyRow(ruleIndex: null, tsSource: null)];
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      final rows = await source.getRecentAlarms();

      expect(rows.single.notification.ruleIndex, isNull,
          reason: 'matching such a row to rule 0 is a guess dressed as a '
              'fact, and rule 0 is the identity an acknowledge would be sent '
              'under');
      expect(rows.single.notification.tsSource, isNull,
          reason: 'nobody recorded a provenance is not the same fact as the '
              'backend positively recording that it guessed');
    });

    // --------------------------------------------------------------- 12f
    test('a backend that cannot answer history is NOT an empty history',
        () async {
      // The failure class this whole change is about. `[]` is what a plant
      // with no alarms looks like, so answering it for a gateway that
      // declined would report a fact about the wire as a fact about the
      // factory — which is exactly what the old database read was doing.
      final transport = _RecordingTransport()
        ..historyError = const _GatewayRefusal(
            'this gateway serves no alarm history, so there is nothing to '
            'read');
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);

      await expectLater(source.getRecentAlarms(), throwsA(isA<Exception>()),
          reason: 'the refusal is the caller\'s to show; swallowing it into an '
              'empty list is the silent loss this milestone exists to remove');
    });

    // --------------------------------------------------------------- 12g
    test('a failed refresh reports itself and leaves the last list standing',
        () async {
      final transport = _RecordingTransport()
        ..historyRows = [historyRow(title: 'The row that was really there')];
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future)
          as RelayAlarmSource;
      expect(source.historyError, isNull,
          reason: 'the premise: the first read worked');
      expect((await source.history().first).single?.alarm.config.title,
          'The row that was really there');

      transport.historyError = const _GatewayRefusal('the pool is gone');
      transport.push([entry()]);
      await _settle(source);

      expect(source.historyError, isNotNull,
          reason: 'a refresh that failed is a fact the panel holds, not a '
              'line that scrolled past on stderr');
      expect((await source.history().first).single?.alarm.config.title,
          'The row that was really there',
          reason: 'the last answer that WAS an answer stands. Clearing the '
              'list on a failed refresh would blank the page and call it the '
              'plant\'s history — the same lie by a shorter route');
    });

    // --------------------------------------------------------------- 12h
    test('a recovered refresh clears the reported failure', () async {
      final transport = _RecordingTransport()
        ..historyError = const _GatewayRefusal('the pool is gone');
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future)
          as RelayAlarmSource;
      expect(source.historyError, isNotNull,
          reason: 'construction does not throw on a history failure — the '
              'active set is fine and a banner is worth more than a refusal '
              'of the whole alarm surface');

      transport.historyError = null;
      transport.historyRows = [historyRow()];
      transport.push([entry()]);
      await _settle(source);

      expect(source.historyError, isNull,
          reason: 'a stale fault line is a fault line nobody reads');
      expect((await source.history().first), hasLength(1));
    });

    // ---------------------------------------------------------------- 13
    test('the alarm editor is not read-only on a gateway station', () async {
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final preferences = await _prefs(alarms: [knownAlarm()]);
      final container = _container(
        gateway: true,
        preferences: preferences,
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      source.addAlarm(secondAlarm());
      await Future<void>.delayed(Duration.zero);

      final stored = AlarmManConfig.fromJson(jsonDecode(
          (await preferences.getString('alarm_man_config'))!)
          as Map<String, dynamic>);
      expect(stored.alarms.map((a) => a.uid),
          containsAll(<String>['CN04.MOT01', 'CN05.MOT01']));
      expect(source.alarms.map((a) => a.config.uid), contains('CN05.MOT01'));

      source.removeAlarm(secondAlarm());
      await Future<void>.delayed(Duration.zero);
      final after = AlarmManConfig.fromJson(jsonDecode(
          (await preferences.getString('alarm_man_config'))!)
          as Map<String, dynamic>);
      expect(after.alarms.map((a) => a.uid), isNot(contains('CN05.MOT01')));
    });
  });

  group('the gateway client subscribes ALARM.active', () {
    // ---------------------------------------------------------------- 14
    test('a mapping that never mentions it still yields it', () {
      final keyMappings = KeyMappings(nodes: {
        'CN04.MOT01.p_stat': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'x')),
      });

      final keys = GatewayStateMan.subscriptionKeys(keyMappings);

      expect(keys, contains('CN04.MOT01.p_stat'));
      expect(keys, contains(rp.AlarmKeys.active),
          reason: 'the client\'s key set is immutable after construction '
              '(gateway_state_man.dart:37-40), so a key added later is a key '
              'never served — and the runtime symptom is an alarm banner that '
              'simply never updates, with no error anywhere');
    });

    // --------------------------------------------------------------- 14b
    test('create passes that set, rather than computing its own', () {
      final source = _stripComments(
          File('lib/core/gateway_state_man.dart').readAsStringSync());
      // The construction statement, not the enclosing function: `create`'s
      // own brace-matched block is its *parameter list*, and an arm that
      // scanned that would have found nothing and said nothing.
      final construction = _statementAt(source, 'RemoteStateMan(');
      expect(construction, isNotEmpty);
      expect(construction, contains('subscriptionKeys(keyMappings)'),
          reason: 'the behavioural arm above is only worth something if the '
              'production path goes through the function it tests');
    });
  });

  // ------------------------------------------------------- CR-01 (14-REVIEW)
  //
  // `GatewayStateMan.updateKeyMappings` returns a non-empty `reloadReasons`
  // unconditionally, and `requiresReload` is `reloadReasons.isNotEmpty`. So in
  // gateway mode EVERY `key_mappings` save takes `state_man.dart:139`'s
  // `ref.invalidateSelf()`, which disposes the `GatewayStateMan` and its
  // `RemoteStateMan`.
  //
  // `alarmManProvider` is `@Riverpod(keepAlive: true)` and read its
  // dependencies with `ref.read`, so nothing invalidated it: the
  // `RelayAlarmSource` kept a `RemoteAlarmTransport` over a disposed client for
  // the life of the process. `RemoteStateMan.dispose` CLOSES its handed-out
  // streams rather than erroring them (`remote_state_man.dart:1219-1222`), so
  // `_listen`'s `onError` never fires: the banner freezes at whatever it showed
  // when the operator saved, a conveyor jams twenty minutes later, and nothing
  // on the screen or on stderr says a word.
  //
  // Two halves, and the second is not optional. Making the source follow the
  // client's lifetime fixes the path we know about; making a stream that ENDS
  // loud is what covers the paths we do not.
  group('the alarm source follows the relay client (CR-01)', () {
    // ----------------------------------------------------------------- 15
    test('a key_mappings reload repoints the alarm source at the new client',
        () async {
      final first = _RecordingTransport();
      final second = _RecordingTransport();
      addTearDown(first.close);
      addTearDown(second.close);

      final container = _reloadableGatewayContainer(
        preferences: await _prefs(alarms: [knownAlarm()]),
        transports: [first, second],
      );

      final before = await container.read(alarmManProvider.future);
      await _settle(before);
      expect(first.subscribed, [rp.AlarmKeys.active],
          reason: 'the premise: the first client is the one being read');

      // Exactly what `state_man.dart:136-140` does on every gateway-mode
      // key_mappings save. The slot is cleared by the old build's onDispose and
      // filled by the new one, as production does.
      container.invalidate(stateManProvider);

      final after = await container.read(alarmManProvider.future);
      await _settle(after);

      expect(identical(before, after), isFalse,
          reason: 'the same source object came back after the client behind it '
              'was disposed. Everything below is a consequence of this one '
              'fact.');
      expect(second.subscribed, [rp.AlarmKeys.active],
          reason: 'the new client was never asked for ALARM.active, so the '
              'banner is reading a socket that is gone — silently, because a '
              'disposed RemoteStateMan CLOSES its streams rather than erroring '
              'them');

      // The operator-visible half: the plant reports a new fault after the
      // save, and the panel must show it.
      second.push([entry(uid: 'CN09.JAM01', title: 'Conveyor jam')]);
      final active = await _settle(after);
      expect(active.map((a) => a.alarm.config.uid), ['CN09.JAM01'],
          reason: 'a fault that arrived after a key-mappings save never '
              'reached the banner. Got: ${active.map((a) => a.alarm.config.uid)}');
    });

    // ---------------------------------------------------------------- 15b
    test('and the source it replaces is closed, not leaked', () async {
      final first = _RecordingTransport();
      final second = _RecordingTransport();
      addTearDown(first.close);
      addTearDown(second.close);

      final container = _reloadableGatewayContainer(
        preferences: await _prefs(alarms: [knownAlarm()]),
        transports: [first, second],
      );

      final before = await container.read(alarmManProvider.future);
      await _settle(before);
      expect(first.hasListener, isTrue,
          reason: 'the premise: something is listening through the first port');

      container.invalidate(stateManProvider);
      await container.read(alarmManProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(first.hasListener, isFalse,
          reason: 'RelayAlarmSource.close() had no caller anywhere '
              '(relay_alarm_source.dart:448), so every gateway-mode rebuild '
              'left a subscription, two BehaviorSubjects and a _reloadHistory '
              'chain behind on a client that no longer exists');
    });

    // ---------------------------------------------------------------- 15c
    test('a transport whose stream ENDS is reported, not silent', () async {
      final transport = _RecordingTransport();
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source =
          await container.read(alarmManProvider.future) as RelayAlarmSource;
      transport.push([entry()]);
      await _settle(source);
      expect(source.activeStreamClosed, isFalse,
          reason: 'the premise: nothing is wrong yet');

      // What `RemoteStateMan.dispose` does to every stream it handed out: it
      // CLOSES them. No error, no exception, no line anywhere.
      await transport.close();
      await _settle(source);

      expect(source.activeStreamClosed, isTrue,
          reason: 'ALARM.active stopped arriving and the source had no opinion '
              'about it. The banner keeps showing the last set it saw, for as '
              'long as the panel is up, and "we cannot read the alarm list" is '
              'indistinguishable from "the plant is fine" — which is the '
              'failure class this whole milestone exists to remove');
    });

    // ---------------------------------------------------------------- 15d
    test('and the acknowledge refuses by name rather than pretending',
        () async {
      final transport = _RecordingTransport();
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source =
          await container.read(alarmManProvider.future) as RelayAlarmSource;
      transport.push([entry()]);
      final active = await _settle(source);
      final alarm = active.single;

      await transport.close();
      await _settle(source);

      await expectLater(
        source.ackAlarm(alarm),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains(rp.AlarmKeys.active), contains('acknowledge')))),
        reason: 'the operator presses Acknowledge on a banner that has been '
            'frozen for twenty minutes. What they got was '
            '"RemoteStateMan was asked for \\"ackAlarm\\" after it was '
            'disposed" — a sentence about an object, from a package they have '
            'never heard of, that does not say the alarm list stopped arriving',
      );
      expect(transport.acks, isEmpty,
          reason: 'and nothing was sent into a socket that is gone');
    });

    // ---------------------------------------------------------------- 15e
    test('an ordinary close() is NOT reported as a dead transport', () async {
      // The negative half, and it is run in both directions in the sabotage
      // matrix. A source that reported every teardown would make 15c pass
      // vacuously — and on a panel it would print a fault line on every
      // key-mappings save, which is how a real one stops being read.
      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source =
          await container.read(alarmManProvider.future) as RelayAlarmSource;
      await _settle(source);

      await source.close();
      await Future<void>.delayed(Duration.zero);

      expect(source.activeStreamClosed, isFalse,
          reason: 'this source was closed on purpose; nothing failed');
    });

    // ---------------------------------------------------------------- 15f
    test('nor is a teardown that takes the transport down with it', () async {
      // 15e alone is not evidence for the `_closing` guard, and that was
      // MEASURED: deleting `_closing = true` from `close()` turned nothing red,
      // because cancelling a StreamSubscription does not fire `onDone` at all.
      // The guard exists for the ordering 15e cannot reach — the client going
      // down in the same breath as the panel tears the source down, which is
      // what `stateManProvider`'s own `onDispose` does one line after this
      // provider's.
      //
      // The order below is the deterministic one: `StreamController.close()`
      // SCHEDULES its done event rather than delivering it, and
      // `RelayAlarmSource.close()` sets `_closing` synchronously before its
      // first await. So the flag is set before the done event runs — unless it
      // is not set at all, and then a routine key-mappings save prints a
      // gateway-is-dead line on every panel in the plant. A fault line that
      // cries wolf on every save is a fault line nobody reads, which is the
      // same silence by a longer route.
      final transport = _RecordingTransport();
      final container = _container(
        gateway: true,
        preferences: await _prefs(alarms: [knownAlarm()]),
        transport: transport,
      );

      final source =
          await container.read(alarmManProvider.future) as RelayAlarmSource;
      await _settle(source);

      final closingTransport = transport.close();
      final closingSource = source.close();
      await closingTransport;
      await closingSource;
      await Future<void>.delayed(Duration.zero);

      expect(source.activeStreamClosed, isFalse,
          reason: 'the client and the source went down together, on purpose. '
              'Nothing failed, and nothing should be reported.');
    });
  });
}
