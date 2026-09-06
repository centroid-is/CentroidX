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
/// [AlarmTransport] exists as a two-member port.
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

  group('panel-side evaluation is structurally absent (D-10, pin 2 of 2)', () {
    // ------------------------------------------------------------------ 4
    test('the gateway branch names no AlarmMan.create and no Evaluator', () {
      final source =
          _stripComments(File('lib/providers/alarm.dart').readAsStringSync());

      final branch = _blockAfter(source, 'gateway.isGateway');
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
            AlarmActive alarm) async =>
        tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: ViewActiveAlarm(alarm: alarm)),
          ),
        ));

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

  group('everything else a gateway-mode panel still does (D-11)', () {
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
    test('getRecentAlarms reads the panel\'s own database', () async {
      await appDb.into(appDb.alarmHistory).insert(
            AlarmHistoryCompanion.insert(
              alarmUid: 'CN04.MOT01',
              alarmTitle: 'Motor overload',
              alarmDescription: 'the drive tripped',
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

      final transport = _RecordingTransport();
      addTearDown(transport.close);
      final container = _container(
        gateway: true,
        preferences:
            await _prefs(alarms: [knownAlarm()], database: database),
        transport: transport,
      );

      final source = await container.read(alarmManProvider.future);
      final rows = await source.getRecentAlarms();

      expect(rows, hasLength(1),
          reason: 'the panel holds its own Postgres connection in gateway '
              'mode too (preferences.dart:37-40), so history is not the '
              'gateway\'s to serve');
      expect(rows.single.notification.ruleIndex, 1);
      expect(rows.single.notification.rule.acknowledgeRequired, isTrue,
          reason: 'the row names rule 1 of the LOCAL configuration, which is '
              'where a historical row\'s rule has always come from');
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
}
