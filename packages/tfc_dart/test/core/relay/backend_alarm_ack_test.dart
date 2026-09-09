/// The backend's acknowledge: what it silences, what it records, and the one
/// thing it must **not** do.
///
/// ## The property this file exists for
///
/// An acknowledgement is the operator saying *"I have seen this"*. It is not
/// the plant saying *"this is over"*. The obvious implementation conflates the
/// two — it takes the entry out of the active set and closes the
/// `alarm_history` row in the same breath — and the consequence is silent and
/// in the direction nobody audits: a stop that ran for two hours is reported
/// as having ended the moment somebody pressed a button, and the downtime
/// report is quietly wrong. `alarmHistoryOverlaps` (`alarm.dart:205-211`)
/// exists to get exactly that number right.
///
/// So the engine's acknowledge **silences and records**; it closes a row only
/// when the condition had already cleared and the entry was being held for an
/// acknowledgement (D-4's `acknowledged` reason). The durable half of that —
/// `acknowledged_at` written, `deactivated_at` still NULL — is measured
/// against a real Postgres in `test/integration/alarm_ack_e2e_test.dart`,
/// because the column is a column and SQLite would not be evidence about it.
/// **This file owns the in-memory half**: the published set, the idempotency,
/// the adapter and the wiring.
///
/// ## Two alarms, not one (14-11's lesson, inherited)
///
/// Arm 2 runs **two** alarms on purpose. With one, "the acknowledged entry
/// stays out of the published set" and "nothing is published at all" are the
/// same observation, and a mutation that dropped the acknowledged mark would
/// turn nothing red — the watcher's own boolean dedup absorbs a repeated true
/// one layer down, so a still-true rule produces no further transition to
/// re-add anything on. A second alarm rising afterwards is what forces a
/// publication whose *contents* can then be wrong.
///
/// ## No socket, no database, no wall clock
///
/// 14-05's kit: the shared fake `BackendValueSource`, a recording publisher,
/// an in-memory `Preferences` and a `CountingClock`. `DateTime.now(` appears
/// nowhere in this file, and arm 6 asserts it appears nowhere in the engine
/// either.
library;

import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarm_ack.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import 'fake_backend_value_source.dart';

/// A second plant instant, so a re-activation can be told from the first one.
final DateTime t1 = t0.add(const Duration(minutes: 5));

/// A third, for the second alarm in arm 2.
final DateTime t2 = t0.add(const Duration(minutes: 10));

void main() {
  group('AlarmEngine.acknowledge', () {
    // --------------------------------------------------------------- arm 1
    test('arm 1 — acknowledging a standing alarm drops it from the PUBLISHED '
        'set, not merely from a map', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(_entriesOf(h.publisher.records.last), hasLength(1),
          reason: 'the alarm has to be standing before it can be silenced');

      final publicationsBefore = h.engine.publications;
      await h.engine.acknowledge('seal', 0);
      await settle();

      expect(h.engine.publications, publicationsBefore + 1,
          reason: 'an acknowledge that changes what is on the banner is a '
              'change every connected panel must be told about');
      expect(_entriesOf(h.publisher.records.last), isEmpty,
          reason: 'asserted against what the PUBLISHER was handed, so '
              '"dropped" means the panels were told rather than that an '
              'internal map moved. A banner that still shows an acknowledged '
              'alarm is an acknowledge button that does nothing.');
      expect(h.engine.active, isEmpty,
          reason: 'and the engine\'s own observation surface agrees');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 2
    test('arm 2 — and it does NOT come back while the condition stays true, '
        'even when something else republishes the set', () async {
      // TWO alarms, and the second one is the whole arm. See the library doc:
      // with one alarm, a publication whose contents are wrong and no
      // publication at all are indistinguishable.
      final h = await _Harness.create([
        _alarm('seal', ['a > 10']),
        _alarm('door', ['b > 10']),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      await h.engine.acknowledge('seal', 0);
      await settle();
      final afterAck = h.engine.publications;

      // Three more updates that keep the rule TRUE. The watcher dedups on the
      // boolean, so these produce no transition at all — which is the point:
      // nothing here may republish, and nothing here may re-add.
      for (var i = 1; i <= 3; i++) {
        h.values.push('a', good(20.0 + i, at: t0.add(Duration(seconds: i))));
      }
      await settle();
      expect(h.engine.publications, afterAck,
          reason: 'a still-true acknowledged rule must not fan out to every '
              'connected panel per value update');

      // Now the OTHER alarm rises. That is a real change and a real
      // publication — and the acknowledged entry must not ride back in on it.
      h.values.push('b', good(20.0, at: t2));
      await settle();

      expect(h.engine.publications, afterAck + 1);
      final entries = _entriesOf(h.publisher.records.last);
      expect(entries.map((e) => e.uid).toList(), ['door'],
          reason: 'the acknowledged alarm blinked back onto the banner the '
              'moment an unrelated alarm caused a republication. An alarm '
              'that reappears at tick rate makes the acknowledge button look '
              'broken, which is worse than not having one.');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 3
    test('arm 3 — it DOES come back after a clear and a re-activation, with a '
        'new onset', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      await h.engine.acknowledge('seal', 0);
      await settle();
      expect(_entriesOf(h.publisher.records.last), isEmpty);

      // The plant fixes itself...
      h.values.push('a', good(1.0, at: t0.add(const Duration(minutes: 1))));
      await settle();
      expect(_entriesOf(h.publisher.records.last), isEmpty);

      // ...and then goes wrong again. A NEW occurrence.
      h.values.push('a', good(30.0, at: t1));
      await settle();

      final entries = _entriesOf(h.publisher.records.last);
      expect(entries.map((e) => e.uid).toList(), ['seal'],
          reason: 'an acknowledgement silences one OCCURRENCE, not the rule. '
              'A mark that survives the transition to false silences the alarm '
              'forever, and the second time the seal bar overheats nobody is '
              'told.');
      expect(entries.single.activeAtMs, t1.millisecondsSinceEpoch,
          reason: 'and it is a new onset — the plant\'s instant for the second '
              'occurrence, not a resurrected copy of the first');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 4
    test('arm 4 — acknowledging twice completes, and the second one publishes '
        'nothing', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      await h.engine.acknowledge('seal', 0);
      await settle();
      final afterFirst = h.engine.publications;
      final recordsAfterFirst = h.publisher.records.length;

      // Two operators on two panels pressing the same button is the ORDINARY
      // case. 14-12's wire carries no idempotency key because the acknowledge
      // is idempotent by construction; this is where that claim is paid for.
      await expectLater(h.engine.acknowledge('seal', 0), completes);
      await settle();

      expect(h.engine.publications, afterFirst,
          reason: 'the set did not move, so the wire must not either');
      expect(h.publisher.records, hasLength(recordsAfterFirst));

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 5
    test('arm 5 — acknowledging something that is not there completes, and '
        'says so in the log', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      final before = h.engine.publications;

      // The panel that sent it was a moment behind — the alarm cleared while
      // the frame was in flight, or a second operator got there first. That is
      // a race an operator cannot avoid, and a throw here surfaces to them as
      // `handlerFailed`: told something is broken when nothing is.
      await expectLater(h.engine.acknowledge('seal', 7), completes);
      await expectLater(h.engine.acknowledge('no-such-alarm', 0), completes);
      await settle();

      expect(h.engine.publications, before);
      expect(h.logs.where((l) => l.contains('no-such-alarm')), isNotEmpty,
          reason: 'not an error, but not silence either: an acknowledge that '
              'matched nothing is worth one line, because a panel sending them '
              'steadily is a panel whose view of the plant has diverged');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 6
    test('arm 6 — the receipt instant comes from the INJECTED clock, read '
        'exactly once, and the engine never reads a real one', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      final readsBefore = h.clock.reads;
      await h.engine.acknowledge('seal', 0);
      await settle();

      expect(h.clock.reads, readsBefore + 1,
          reason: 'D-2. An acknowledgement is a human act at the BACKEND — '
              'there is no plant sourceTime for it — so it is stamped from the '
              'injected clock, once. Twice would be two readings inside one '
              'logical instant, which can straddle a second.');

      // The other half of D-2, and it is a source scan rather than a promise.
      // `alarm_structure_test.dart` arm 6 already pins the five files on the
      // alarm path; this is the same pin at the point of the edit, so a
      // `DateTime.now()` smuggled into the acknowledge fails here first with a
      // message that names the reason.
      // Comments stripped first, exactly as `alarm_structure_test.dart` does:
      // the engine's own doc SAYS the words `DateTime.now(` in the paragraph
      // explaining that it never calls it, and a scan that could not tell the
      // two apart would be a gate nobody could satisfy.
      final engineSource = _code('lib/core/relay/backend_alarms.dart');
      expect('DateTime.now('.allMatches(engineSource), isEmpty,
          reason: 'the engine may not read a real clock. The composition root '
              'supplies one, and bin/main.dart is the only place in the '
              'backend alarm path that spells it.');
      expect(engineSource.contains('tfc_relay_server'), isFalse,
          reason: 'and the engine may not name the gateway either: D-8 has it '
              'constructed unconditionally while the relay section is '
              'optional, so an engine that imported the gateway\'s types could '
              'not be built by a backend running without a WebSocket');

      // The DURABLE instant — the value that actually lands in
      // `acknowledged_at` — is asserted against a real Postgres in
      // `test/integration/alarm_ack_e2e_test.dart` arm 2. There is no column
      // here to read it out of, and a fake writer asserting that the engine
      // handed it the number it was going to hand it is not evidence.

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 7
    test('arm 7 — the sink is a thin adapter: one call through, both arguments '
        'unchanged, no opinion of its own', () async {
      final engine = _RecordingAcknowledger();
      final sink = BackendAlarmAckSink(engine);

      await sink.acknowledge('CN04.MOT01', 3);

      expect(engine.calls, [('CN04.MOT01', 3)],
          reason: 'one call, the same two values, in the same order');

      // And it filters NOTHING. Authorization is the gateway's (14-12), and a
      // second opinion here would be a second place to get it wrong; an alarm
      // the engine has never heard of is the engine's to shrug at, not the
      // adapter's to refuse.
      await sink.acknowledge('never-existed', 0);
      expect(engine.calls, hasLength(2));

      expect(identical(sink.engine, engine), isTrue,
          reason: 'the sink holds the engine it was given — arm 9 reads this '
              'to say the composition wired the right one');

      // Thin by measurement, not by intention. A fat adapter is policy that
      // escaped the gateway.
      final body = _code('lib/core/relay/backend_alarm_ack.dart')
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .length;
      expect(body, lessThan(25),
          reason: 'the adapter grew a body. Everything it could usefully do '
              '— authorize, filter, log, retry — is somebody else\'s job, and '
              'doing it here is doing it twice');
    });

    // --------------------------------------------------------------- arm 8
    test('arm 8 — the engine\'s failure reaches the sink\'s caller instead of '
        'being swallowed', () async {
      final engine = _RecordingAcknowledger(
          throws: StateError('the database refused the acknowledgement'));
      final sink = BackendAlarmAckSink(engine);

      await expectLater(
        sink.acknowledge('CN04.MOT01', 0),
        throwsA(isA<StateError>()),
        reason: '14-12 turns a throw here into `handlerFailed`, which is the '
            'answer the operator needs. Swallowing it answers success: an '
            'operator told the alarm was acknowledged, watching it sit on the '
            'banner, with nothing anywhere saying why.',
      );
      expect(engine.calls, hasLength(1),
          reason: 'and it really did reach the engine before it failed');
    });

    // --------------------------------------------------------------- arm 9
    test('arm 9 — composeBackendRelay fills the gateway\'s seam with the '
        'engine, and leaves it empty when there is none', () async {
      final tmp = Directory.systemTemp.createTempSync('backend-alarm-ack');
      final database = Database(await AppDatabase.create(
        DatabaseConfig(applicationName: 'backend-alarm-ack-test'),
        sqliteFolder: tmp,
      ));
      addTearDown(() async {
        await database.close();
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final prefs = await Preferences.create(db: database);

      BackendRelayComposition compose({GatewayAlarmEngine? alarms}) {
        final composed = composeBackendRelay(
          config: RelayConfig.fromJson(_relaySection(), source: 'stateman.json')!,
          pipe: PipeMainEndpoint(),
          keyMappings: _mappings(),
          database: database,
          prefs: prefs,
          alarms: alarms,
          log: Logger(level: Level.off),
        );
        addTearDown(composed.dispose);
        return composed;
      }

      final engine = _RecordingAcknowledger();
      final withEngine = compose(alarms: engine);
      final sink = withEngine.server.alarmAcks;
      expect(sink, isA<BackendAlarmAckSink>(),
          reason: 'the seam 14-12 added is optional and defaults to null, so a '
              'composition that forgets it produces a gateway that refuses '
              'every acknowledge by name — with no test noticing');
      expect(identical((sink! as BackendAlarmAckSink).engine, engine), isTrue,
          reason: 'and it must be THIS engine: a sink over a second one would '
              'acknowledge into an object no panel is served from');

      // Both branches, because a backend running with the relay section absent
      // (D-8) must still compose — and one running with a relay but no alarm
      // engine must refuse an acknowledge by name rather than accept it into
      // nothing.
      expect(compose().server.alarmAcks, isNull);
    });
  });
}

// ------------------------------------------------------------------ fixtures

/// [path]'s source with `//` and `///` lines removed.
///
/// Line comments only, which is all these two files carry above the code the
/// arms are scanning for. Block comments appear in neither.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

List<relay.AlarmActiveEntry> _entriesOf(_Record record) =>
    relay.AlarmActiveEntry.decodeList(record.value.toJson(slim: true)).entries;

Map<String, dynamic> _relaySection() => <String, dynamic>{
      'relay': <String, dynamic>{
        'port': 0,
        'credentials': <String, dynamic>{'source': 'none'},
      },
    };

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in const <String>['ST101.CN01.MOT01.speed'])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key)
            ..serverAlias = key.split('.').first,
        ),
    });

AlarmConfig _alarm(
  String uid,
  List<String> formulas, {
  String title = 'A title',
  String description = 'A description',
  AlarmLevel level = AlarmLevel.error,
  bool acknowledgeRequired = false,
}) =>
    AlarmConfig(
      uid: uid,
      title: title,
      description: description,
      group: const [],
      rules: [
        for (final formula in formulas)
          AlarmRule(
            level: level,
            expression: ExpressionConfig(value: Expression(formula: formula)),
            acknowledgeRequired: acknowledgeRequired,
          ),
      ],
    );

/// An engine, its fakes and everything the arms read off them.
///
/// 14-05's kit, copied rather than shared for one reason: this file's arms need
/// a `CountingClock` they can read the tally off, and `backend_alarms_test.dart`
/// keeps its harness library-private on purpose.
final class _Harness {
  _Harness._(this.values, this.publisher, this.logs);

  static Future<_Harness> create(List<AlarmConfig> alarms) async {
    final preferences = InMemoryPreferences();
    await preferences.setString(
        kAlarmManConfigKey, jsonEncode(AlarmManConfig(alarms: alarms).toJson()));

    final logs = <String>[];
    final h = _Harness._(FakeBackendValueSource(), _RecordingPublisher(), logs);
    h.engine = AlarmEngine(
      values: h.values,
      preferences: preferences,
      publisher: h.publisher,
      clock: h.clock.call,
      logger: Logger(
        filter: ProductionFilter(),
        level: Level.all,
        printer: SimplePrinter(colors: false),
        output: _RecordingOutput(logs),
      ),
    );
    return h;
  }

  final FakeBackendValueSource values;
  final _RecordingPublisher publisher;
  final List<String> logs;
  final CountingClock clock = CountingClock(t0.add(const Duration(hours: 6)));
  late final AlarmEngine engine;

  Future<void> dispose() async {
    await engine.dispose();
    await values.dispose();
  }
}

typedef _Record = ({String key, relay.DynamicValue value});

final class _RecordingPublisher implements AlarmStatePublisher {
  final List<_Record> records = [];

  @override
  void publish(String key, relay.DynamicValue value) =>
      records.add((key: key, value: value));
}

final class _RecordingOutput extends LogOutput {
  _RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

/// A [GatewayAlarmEngine] that records acknowledges, and optionally fails.
///
/// The reason [AlarmAcknowledger] exists at all: `AlarmEngine` is a `final
/// class`, so nothing can stand in for it, and the two properties arms 7 and 8
/// are about — the adapter passes through unchanged, and it does not swallow —
/// are properties of the adapter that cannot be observed with the real engine
/// on the other side of them.
final class _RecordingAcknowledger implements GatewayAlarmEngine {
  _RecordingAcknowledger({this.throws});

  final Object? throws;
  final List<(String, int)> calls = <(String, int)>[];

  /// No definitions, which is what a recorder honestly has.
  ///
  /// `composeBackendRelay` takes the acknowledge and the history definitions as
  /// ONE argument, so that a composition cannot wire one and forget the other —
  /// the shape of the defect the history seam shipped with. The cost lands
  /// here: a fake for either capability answers for both, and this one answers
  /// null, which the history reader treats as "nothing configured claims this
  /// row" rather than as a failure.
  @override
  AlarmManConfig? get config => null;

  @override
  Future<void> acknowledge(String alarmUid, int ruleIndex) async {
    calls.add((alarmUid, ruleIndex));
    final failure = throws;
    if (failure != null) throw failure;
  }
}
