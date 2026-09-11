/// The acknowledge, measured end to end: a panel, a real socket, the composed
/// backend, and a real `alarm_history` row.
///
/// ## The property this file exists for, and it is not the obvious one
///
/// The obvious property — the alarm leaves the banner — is arm 1, and it is the
/// easy half. The property a reviewer will not think to ask for is arm 3:
/// **acknowledging an alarm whose condition is still true must leave its
/// `alarm_history` row OPEN.** An acknowledgement is the operator saying *"I
/// have seen this"*, not the plant saying *"this is over"*. The naive
/// implementation closes the row in the same breath as it clears the banner,
/// and the consequence is silent and in the direction nobody audits: a stop
/// that ran for two hours is reported as having ended the moment somebody
/// pressed a button. `alarmHistoryOverlaps` (`alarm.dart:205-211`) exists to
/// get exactly that number right.
///
/// So arms 3 and 4 are a pair — the row stays open, and then the PLANT closes
/// it as `cleared` at the plant's own instant — and arm 5 is the other order:
/// a rule that had already gone false and was being held for an acknowledgement
/// closes as `acknowledged`, at the **clearing evaluation's** instant, never at
/// the acknowledgement's.
///
/// ## Why this file is in the Docker lane at all
///
/// `acknowledged_at` has existed on `alarm_history` since the table was created
/// and, until the plan this file belongs to, **nothing had ever written it**
/// (14-RESEARCH). A column's first write is not a claim a fake can carry: arms
/// 2, 3, 4 and 5 read the row back off a real Postgres through a raw driver, so
/// what they judge is what the server holds.
///
/// **Port 15432 is hardcoded in `docker_compose.dart` and a parallel worktree
/// run collides** (project memory `tfc-dart-integration-port-collision`). Run
/// this file ALONE, or with `--concurrency=1` alongside the other db-tagged
/// files: `dart test` schedules files concurrently by default and two
/// Postgres-backed integration files starting together race for that port,
/// producing `Address already in use` failures that look like real ones.
///
/// ## The wire is real, and the panels are two sessions
///
/// 14-11's `BackendRelayFixture`, extended: the same `composeBackendRelay` the
/// binary calls, bound on an OS-chosen loopback port, with two independent
/// client sockets in front of it. Two panels because criterion 5's property is
/// that they *agree*, and an acknowledge that cleared one screen and not the
/// other would be a worse defect than no acknowledge at all — arm 7 records
/// every active set both panels ever observed and requires the sequences to be
/// equal.
///
/// **The frame is the client's frame.** `BackendRelayClient.ackAlarm` builds
/// `AckAlarmParams` and names `Methods.ackAlarm`, which is the same
/// construction `RemoteStateMan.ackAlarm` uses (14-13), out of the same
/// protocol package. A hand-written map would have made this file's agreement
/// with the gateway evidence about a map.
///
/// ## The heartbeat is not optional
///
/// Nothing the gateway *sends* keeps a session alive (`relay_session.dart:1264`)
/// — only inbound frames move `_lastSeen`, and the deadline is six seconds. The
/// harness beats at a third of the deadline the gateway advertised, and every
/// arm here that makes a claim about what a panel holds first asserts that the
/// panel is **still attached**. 14-11 found an arm asserting a property about
/// two panels that had been disconnected for four seconds; it was true because
/// nobody was there to be told otherwise.
@TestOn('vm')
@Tags(['db', 'ws'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:math';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart' show Database, DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
// Reaching into `tfc_relay_server/lib/src/` for the same reason the harness
// does with `ws_channel.dart`: `ServerErrorCodes` is not on the barrel, and the
// alternative is a bare `-32005` in an assertion — a number that stops meaning
// "forbidden" the day somebody renumbers the table, with nothing failing.
import 'package:tfc_relay_server/src/error_codes.dart' show ServerErrorCodes;
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessSession, AuthenticatedUser;
import 'package:tfc_relay_server/tfc_relay_server.dart'
    show
        StationIdentity,
        TokenAccepted,
        TokenRejected,
        TokenValidator,
        TokenVerdict;

import '../support/backend_ws_harness.dart';
import '../support/harnessed_backend_state_man.dart';
import 'docker_compose.dart';

// ---------------------------------------------------------------------------
// Instants. Three, and they are all different on purpose.
// ---------------------------------------------------------------------------

/// The plant's instant for every activation in this file.
final DateTime plantOnset = DateTime.utc(2024, 3, 1, 12, 0, 0, 250);

/// The plant's instant for a clear, an hour later.
final DateTime plantClear = plantOnset.add(const Duration(hours: 1));

/// What the BACKEND's injected clock reads, all run long.
///
/// Two years and a bit from either plant instant, and no wall clock on any
/// machine running this suite can produce it. That distance is what makes arm
/// 2's equality mean something: `acknowledged_at` can only be this number if
/// the engine took it from the clock it was injected with, and arm 4's
/// `deactivated_at` can only be [plantClear] if the close took the PLANT's.
final DateTime backendNow = DateTime.utc(2024, 3, 1, 18, 30, 0);

// ---------------------------------------------------------------------------
// The alarms
// ---------------------------------------------------------------------------

const String kInputKey = contractSpeedKey;
const String kAlarmUid = 'conveyor-overspeed';

/// The second alarm's input — a different line, so the two never interact.
const String kHeldInputKey = 'ST201.CN04.MOT01.speed';

/// An `acknowledgeRequired` alarm: it stays on the banner after the condition
/// goes false, badged, until somebody acknowledges it. Arm 5's, and only
/// arm 5's.
const String kHeldAlarmUid = 'packer-overspeed';

const String kSub = 'panel';

/// The credential each panel presents. Two stations, two roles.
const String kOperateToken = 'token-for-the-panel-beside-the-machine';
const String kViewToken = 'token-for-the-canteen-wall-display';

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

final String runSuffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

final String databaseName = 'alarm_ack_e2e_$runSuffix';

late pg.Connection admin;
late pg.Connection conn;
late AppDatabase appDatabase;
late Database database;
late Preferences preferences;

bool fixtureUp = false;

/// A secure store that refuses, so this process never reaches a keychain.
///
/// `Preferences.create` asks `SecureStorage.getInstance()` unconditionally and
/// the default instance prompts for the login keychain on every fresh binary
/// (project memory `macos-debug-keychain-prompts`). Nothing here wants secret
/// material — the "tokens" below are opaque strings a fixture validator
/// compares, and they never leave this isolate.
final class RefusingSecureStorage implements MySecureStorage {
  const RefusingSecureStorage();

  static Never _refuse(String op) => throw StateError(
      'the alarm acknowledge lane handles no secret material: $op was asked of '
      'the refusing secure store');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

/// Two stations, two authorities, judged off the token in the `hello`.
///
/// **This is why the fixture needs a validator at all.**
/// `PermissiveTokenValidator` — the default, and the one every other leg in
/// this workspace runs on — answers the operate group for everybody,
/// deliberately and honestly: "everyone may do everything" is what it means.
/// So a view-only session does not exist without a validator that mints one,
/// and arm 6 would have had nothing to measure.
///
/// 17-04b's user model: the token names an account, and the groups on the
/// session are what the server resolved for that account — here spelled as
/// literals because this fixture IS the resolver. An empty group set is the
/// wall display's whole authority.
///
/// Refusing an unknown token rather than defaulting it: a fixture whose
/// default is operate would let a panel that forgot its token pass arm 6 for
/// the wrong reason.
final class RoleTokenValidator implements TokenValidator {
  const RoleTokenValidator();

  static const AuthenticatedUser _packUser = AuthenticatedUser(
      username: 'PACK-02-panel',
      roleName: 'Panel Operator',
      stationAccount: true);
  static const AuthenticatedUser _canteenUser = AuthenticatedUser(
      username: 'CANTEEN-01-display',
      roleName: 'Hall Display',
      stationAccount: true);

  static const Map<String, StationIdentity> _stations =
      <String, StationIdentity>{
    kOperateToken: StationIdentity(
        user: _packUser,
        station: 'PACK-02',
        session:
            AccessSession(user: _packUser, groups: {AccessGroup.operate})),
    kViewToken: StationIdentity(
        user: _canteenUser,
        station: 'CANTEEN-01',
        session: AccessSession(user: _canteenUser, groups: {})),
  };

  @override
  Future<TokenVerdict> validate(relay.HelloParams params) async {
    final identity = _stations[params.token];
    if (identity == null) {
      // Names the station's client id and never the credential (T-06-26).
      return TokenRejected('no station in this fixture presents that '
          'credential (client "${params.client.name}")');
    }
    return TokenAccepted(identity);
  }
}

DatabaseConfig configFor(String name) {
  final base = getTestConfig();
  final endpoint = base.postgres!;
  return DatabaseConfig(
    postgres: pg.Endpoint(
      host: endpoint.host,
      port: endpoint.port,
      database: name,
      username: endpoint.username,
      password: endpoint.password,
    ),
    sslMode: base.sslMode,
    connectTimeout: base.connectTimeout,
    queryTimeout: base.queryTimeout,
    applicationName: 'alarm_ack_e2e_test',
  );
}

Future<pg.Connection> connectTo(String name) => pg.Connection.open(
      configFor(name).postgres!,
      settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
    );

// ---------------------------------------------------------------------------
// Row access — raw, so the arms judge what the server holds
// ---------------------------------------------------------------------------

typedef HistoryRow = Map<String, Object?>;

Future<List<HistoryRow>> historyRows() async {
  final rows = await conn.execute('''
    SELECT id, alarm_uid, rule_index, active, pending_ack,
           created_at, deactivated_at, acknowledged_at, deactivated_reason
      FROM alarm_history
     ORDER BY id
  ''');
  return <HistoryRow>[for (final row in rows) row.toColumnMap()];
}

Future<HistoryRow> rowFor(String uid) async {
  final rows = await historyRows();
  final matching = rows.where((r) => r['alarm_uid'] == uid).toList();
  expect(matching, hasLength(1),
      reason: 'exactly one alarm_history row for "$uid" — the v7 partial '
          'unique index on (alarm_uid, rule_index) WHERE deactivated_at IS '
          'NULL makes a second OPEN one unrepresentable, and this file never '
          'produces a second closed one. Got: $rows');
  return matching.single;
}

/// A stored instant, read the way drift reads one.
///
/// `created_at`, `deactivated_at` and `acknowledged_at` are TEXT columns
/// (`storeDateTimeAsText`), and a value written through a `::timestamp` cast
/// comes back out as `2026-09-06 12:00:00` with no zone at all. Drift's own
/// `_readDateTime` treats the zoneless case as UTC; so does this, so the arm
/// and the production reader cannot disagree by the machine's UTC offset —
/// which on an Icelandic station is zero and on a developer's laptop is not.
DateTime parseStored(Object? raw) {
  final value = '$raw';
  if (RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(value)) {
    return DateTime.parse(value).toUtc();
  }
  if (value.endsWith('Z')) return DateTime.parse(value).toUtc();
  return DateTime.parse('${value}Z').toUtc();
}

/// An instant as `alarm_history` really holds one after a `::timestamp` cast:
/// UTC, space-separated, and carrying no zone.
String zonelessInstant(DateTime at) {
  final iso = at.toUtc().toIso8601String();
  return iso.substring(0, iso.length - 1).replaceFirst('T', ' ');
}

/// Writes an open row the way a previous process would have left one.
///
/// Through the raw driver rather than through [AlarmHistoryWriter], on 14-06's
/// argument: the restart arm is about what THIS process does with a row it did
/// not write, and seeding through the subject would make it an assertion about
/// the writer agreeing with itself.
///
/// The instants are bound as the **zoneless text** a real row carries, not
/// through a `::timestamp` cast: a bound parameter inside one makes the server
/// infer `timestamp` while the driver has already declared `text`, and the
/// answer is `22P03: incorrect binary data format in bind parameter`.
Future<int> seedOpenRow({
  required String uid,
  required int ruleIndex,
  required DateTime createdAt,
  DateTime? acknowledgedAt,
}) async {
  final rows = await conn.execute(
    pg.Sql.named('''
      INSERT INTO alarm_history (
        alarm_uid, alarm_title, alarm_description, alarm_level,
        expression, active, pending_ack, created_at, deactivated_at,
        acknowledged_at, rule_index, ts_source
      ) VALUES (
        @uid, @title, @description, @level,
        @expression, TRUE, FALSE, @created, NULL,
        @acknowledged, @ruleIndex, @tsSource
      ) RETURNING id
    '''),
    parameters: <String, Object?>{
      'uid': pg.TypedValue(pg.Type.text, uid),
      'title': pg.TypedValue(pg.Type.text, 'left open by a previous process'),
      'description': pg.TypedValue(pg.Type.text, 'seeded'),
      'level': pg.TypedValue(pg.Type.text, 'error'),
      'expression': pg.TypedValue(pg.Type.text, '$kInputKey > 10'),
      'created': pg.TypedValue(pg.Type.text, zonelessInstant(createdAt)),
      'acknowledged': pg.TypedValue(pg.Type.text,
          acknowledgedAt == null ? null : zonelessInstant(acknowledgedAt)),
      // bigInteger: drift's Postgres dialect makes `rule_index` a bigint, and
      // binding an int4 against it fails with SQLSTATE 08P01 rather than with
      // anything that names a type (14-01).
      'ruleIndex': pg.TypedValue(pg.Type.bigInteger, ruleIndex),
      'tsSource': pg.TypedValue(pg.Type.text, 'plant'),
    },
  );
  return rows.first.first! as int;
}

/// Names which of the three clocks an unexpected instant came from.
String diagnose(Object? raw) {
  if (raw == null) return 'It is NULL.';
  final actual = parseStored(raw);
  if (actual == plantOnset) return 'That is the PLANT\'s onset instant.';
  if (actual == plantClear) return 'That is the PLANT\'s clearing instant.';
  if (actual == backendNow) {
    return 'That is the BACKEND\'s injected clock — a receipt instant.';
  }
  if (actual.isAfter(DateTime.utc(2025))) {
    return 'That is a WALL-CLOCK instant — something read a real clock, which '
        'no file on the backend alarm path may do (D-2).';
  }
  return 'It matches none of the three instants this file knows about.';
}

void main() {
  group('acknowledge, end to end over a real socket against a real Postgres',
      () {
    setUpAll(() async {
      SecureStorage.setInstance(const RefusingSecureStorage());
      await startDockerCompose();
      await waitForDatabaseReady();
      admin = await getTestConnection();

      await admin.execute('DROP DATABASE IF EXISTS "$databaseName" WITH (FORCE)');
      await admin.execute('CREATE DATABASE "$databaseName"');

      appDatabase = await AppDatabase.create(configFor(databaseName));
      await appDatabase.open();
      database = Database(appDatabase);
      conn = await connectTo(databaseName);
      preferences = await Preferences.create(db: database);

      fixtureUp = true;
    });

    tearDownAll(() async {
      if (!fixtureUp) return;
      try {
        await conn.close();
      } catch (_) {/* an already-closed connection is not a failure */}
      try {
        await database.close();
      } catch (_) {/* same */}
      try {
        await admin
            .execute('DROP DATABASE IF EXISTS "$databaseName" WITH (FORCE)');
      } catch (_) {/* a leftover database is noise, not a failure */}
      await admin.close();
      await stopDockerCompose();
    });

    setUp(() async {
      await conn.execute('TRUNCATE TABLE alarm_history');
    });

    // ------------------------------------------------------------------ 0 --
    test('arm 0: the panels outlive the reaper — the foundation every other '
        'arm\'s attachment check rests on', () async {
      final rig = await _Rig.standUp();
      final deadline = rig.a.heartbeatDeadline;
      expect(deadline, isNotNull,
          reason: 'the gateway advertised no usable heartbeat deadline, so the '
              'harness runs no pump and every session in this file is on a '
              'six-second fuse it cannot see');

      // Past the deadline, with a margin. Nothing the gateway SENDS keeps a
      // session alive (`relay_session.dart:1264`), so a panel that is merely
      // watching a page is reaped one deadline after its handshake unless it
      // beats — and an arm asserting anything about a reaped panel is
      // vacuously true, which is how 14-11 lost a whole property without
      // noticing.
      await Future<void>.delayed(deadline! * 1.5);

      for (final panel in [rig.a, rig.b]) {
        expect(panel.client.closedByServer, isFalse,
            reason: '${panel.name} was reaped. ${rig.evidence()}');
        expect(panel.client.heartbeats, greaterThan(0),
            reason: '${panel.name} is alive by luck rather than because it did '
                'what a panel does. ${rig.evidence()}');
      }

      // Every other arm in this file finishes well inside one deadline, so its
      // `requireAttached()` is a cheap live check rather than this wait. This
      // arm is what makes that check mean "attached" rather than "not yet
      // noticed missing".
    });

    // ------------------------------------------------------------------ 1 --
    test('arm 1: the acknowledge crosses the wire and the alarm leaves BOTH '
        'panels\' ALARM.active', () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();

      expect(rig.a.uids, [kAlarmUid], reason: rig.evidence());
      expect(rig.b.uids, [kAlarmUid], reason: rig.evidence());

      // Panel A, and only panel A, presses Acknowledge.
      await rig.a.client.ackAlarm(kAlarmUid, 0);
      await rig.awaitSilenced();

      rig.requireAttached();
      expect(rig.a.uids, isEmpty,
          reason: 'the panel that pressed the button still shows the alarm. '
              '${rig.evidence()}');
      expect(rig.b.uids, isEmpty,
          reason: 'panel B was never told. An acknowledge that clears one '
              'screen and not the other is a worse defect than no acknowledge '
              'at all: two operators then disagree about whether anybody has '
              'seen the fault. ${rig.evidence()}');
      expect(rig.backend.engine!.active, isEmpty,
          reason: 'and the engine agrees with both of them');
    });

    // ------------------------------------------------------------------ 2 --
    test('arm 2: the row carries the acknowledgement — acknowledged_at, the '
        'column that had never been written', () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();

      final before = await rowFor(kAlarmUid);
      expect(before['acknowledged_at'], isNull,
          reason: 'nothing may have stamped it before an operator acted, or '
              'the arm below is measuring a column that was already full');

      await rig.a.client.ackAlarm(kAlarmUid, 0);
      await rig.awaitSilenced();
      await rig.backend.engine!.persistenceIdle();

      final row = await rowFor(kAlarmUid);
      expect(row['acknowledged_at'], isNotNull,
          reason: 'an acknowledgement that leaves no row is a screen state, '
              'not a fact (T-14-57). This is the first write this column has '
              'ever received.');
      expect(parseStored(row['acknowledged_at']), backendNow,
          reason: 'the instant is the BACKEND\'s receipt, from the injected '
              'clock (D-2): an acknowledgement is a human act here and there '
              'is no plant sourceTime for it. '
              '${diagnose(row['acknowledged_at'])}');
      expect(parseStored(row['created_at']), plantOnset,
          reason: 'and the onset is untouched — the acknowledgement says '
              'nothing about when the plant went wrong');
    });

    // ------------------------------------------------------------------ 3 --
    test('arm 3: the standing stop is left OPEN — acknowledging is not '
        'clearing', () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();

      await rig.a.client.ackAlarm(kAlarmUid, 0);
      await rig.awaitSilenced();
      await rig.backend.engine!.persistenceIdle();

      // The condition is STILL TRUE: nothing has moved the input back under
      // its limit, and the arm says so out loud rather than assuming it.
      expect(rig.backend.composition.freshness.read(kInputKey)?.value, 42.0,
          reason: 'the input must still be over its limit, or this arm is '
              'about a stop that had already ended. ${rig.evidence()}');

      final row = await rowFor(kAlarmUid);
      expect(row['deactivated_at'], isNull,
          reason: 'THE headline property of this plan. The stop is still '
              'happening. A row closed here reports a stop as having ended the '
              'moment an operator pressed Acknowledge — a two-hour stop '
              'becomes a two-minute one, silently, in the direction nobody '
              'audits, and the downtime report is wrong with nothing anywhere '
              'saying so (T-14-56). Got: ${diagnose(row['deactivated_at'])}');
      expect(row['deactivated_reason'], isNull,
          reason: 'and no reason either: there is nothing to give a reason for');
      expect(row['active'], isTrue,
          reason: 'a row whose alarm is still standing is still an active row');
      expect(row['acknowledged_at'], isNotNull,
          reason: 'while the acknowledgement itself IS recorded — the two '
              'facts are separate columns because they are separate facts');

      // And the engine has not forgotten it. An acknowledged entry it dropped
      // would be a row nothing could ever close.
      expect(rig.backend.engine!.acknowledgedStandingCount, 1,
          reason: 'the engine must still be tracking the acknowledged alarm, '
              'or the open row above has no owner and stays open forever');
    });

    // ------------------------------------------------------------------ 4 --
    test('arm 4: and then the PLANT clears it — the row closes as \'cleared\', '
        'at the plant\'s instant', () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();
      await rig.a.client.ackAlarm(kAlarmUid, 0);
      await rig.awaitSilenced();

      // An hour later the line comes back under its limit.
      rig.clear();
      await rig.backend.engine!.persistenceIdle();
      await _waitUntil(
        () => rig.backend.engine!.acknowledgedStandingCount == 0,
        reason: () => 'the clear never reached the engine. '
            '${rig.evidence()}',
      );
      await rig.backend.engine!.persistenceIdle();

      final row = await rowFor(kAlarmUid);
      expect(row['active'], isFalse);
      expect(parseStored(row['deactivated_at']), plantClear,
          reason: 'the stop ended when the PLANT said it ended, which is an '
              'hour after it started and six and a half hours before this '
              'backend\'s clock reads. ${diagnose(row['deactivated_at'])}');
      expect(row['deactivated_reason'], AlarmHistoryWriter.reasonCleared,
          reason: '\'cleared\' and not \'acknowledged\': this engine watched '
              'the condition go false and knows when. The acknowledgement '
              'happened an hour earlier and did not end anything.');
      expect(parseStored(row['acknowledged_at']), backendNow,
          reason: 'and the acknowledgement survives the close — the two are '
              'different columns holding different facts');
    });

    // ------------------------------------------------------------------ 5 --
    test('arm 5: the other order — a CLEARED alarm held for acknowledgement '
        'closes as \'acknowledged\', at the CLEARING instant', () async {
      final rig = await _Rig.standUp();

      // An `acknowledgeRequired` rule: it goes true, then false, and stays on
      // the banner badged pendingAck. A fault that came and went between two
      // glances at a screen is still a fault somebody must see.
      rig.raiseHeld();
      await _waitUntil(() => rig.a.uids.contains(kHeldAlarmUid),
          reason: () => 'the held alarm never reached panel A. '
              '${rig.evidence()}');

      rig.clearHeld();
      await _waitUntil(
        () => rig.a.entryFor(kHeldAlarmUid)?.pendingAck == true &&
            rig.b.entryFor(kHeldAlarmUid)?.pendingAck == true,
        reason: () => 'the cleared alarm was not held for acknowledgement '
            'on both panels. ${rig.evidence()}',
      );

      await rig.a.client.ackAlarm(kHeldAlarmUid, 0);
      await _waitUntil(
        () => !rig.a.uids.contains(kHeldAlarmUid) &&
            !rig.b.uids.contains(kHeldAlarmUid),
        reason: () => 'the acknowledgement never took the held alarm off '
            'both banners. ${rig.evidence()}',
      );
      await rig.backend.engine!.persistenceIdle();

      rig.requireAttached();
      final row = await rowFor(kHeldAlarmUid);
      expect(row['active'], isFalse);
      expect(row['deactivated_reason'], AlarmHistoryWriter.reasonAcknowledged,
          reason: 'D-4: this row was closed BY the acknowledgement, and a stop '
              'analysis must be able to tell that from one the plant closed. '
              'Compare arm 4, which is the same two columns saying '
              '\'${AlarmHistoryWriter.reasonCleared}\'.');
      expect(parseStored(row['deactivated_at']), plantClear,
          reason: 'and the END is the CLEARING evaluation\'s instant, not the '
              'acknowledgement\'s. The stop ended when the plant said it '
              'ended; the operator merely noticed afterwards, possibly a shift '
              'later. ${diagnose(row['deactivated_at'])}');
      expect(parseStored(row['acknowledged_at']), backendNow,
          reason: 'the acknowledgement\'s own instant lives in its own column, '
              'and it is the backend\'s receipt');
    });

    // ------------------------------------------------------------------ 6 --
    test('arm 6: a VIEW station\'s acknowledge is refused in the composed '
        'backend, and nothing moves', () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();

      final wallDisplay = await rig.joinViewOnly();
      expect(wallDisplay.uids, [kAlarmUid],
          reason: 'the wall display may SEE the alarm — the shipped policy '
              'hides nothing — which is what makes the refusal below about '
              'actuation rather than about visibility');

      Object? refusal;
      try {
        await wallDisplay.client.ackAlarm(kAlarmUid, 0);
      } catch (error) {
        refusal = error;
      }

      expect(refusal, isA<RelayRefusal>(),
          reason: 'a canteen wall display acknowledged a plant alarm. The gate '
              'is 14-12\'s and lives in the gateway; this arm is what proves '
              'it is actually REACHED in the backend the binary composes, '
              'rather than merely present in the server package (T-14-58)');
      expect((refusal! as RelayRefusal).code, ServerErrorCodes.forbidden,
          reason: 'and refused as forbidden — not as an unknown method, not as '
              'a handler failure, both of which send a fitter hunting the '
              'wrong problem. Got: $refusal');

      // Nothing moved. Asserted after a settling window, so "still there" is a
      // measurement rather than a race the arm happens to win.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await rig.backend.engine!.persistenceIdle();

      rig.requireAttached();
      expect(rig.a.uids, [kAlarmUid], reason: rig.evidence());
      expect(rig.b.uids, [kAlarmUid], reason: rig.evidence());
      final row = await rowFor(kAlarmUid);
      expect(row['acknowledged_at'], isNull,
          reason: 'a refused acknowledge that still stamped the row would '
              'record that somebody had seen an alarm nobody was allowed to '
              'acknowledge. ${diagnose(row['acknowledged_at'])}');
    });

    // ------------------------------------------------------------------ 7 --
    test('arm 7: the two panels never disagreed at any point in between',
        () async {
      final rig = await _Rig.standUp();
      rig.raise();
      await rig.awaitStanding();
      await rig.a.client.ackAlarm(kAlarmUid, 0);
      await rig.awaitSilenced();
      rig.clear();
      await _waitUntil(
        () => rig.backend.engine!.acknowledgedStandingCount == 0,
        reason: () => 'the clear never reached the engine. '
            '${rig.evidence()}',
      );
      // One tick plus a margin, so a frame B was owed has had time to land.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      rig.requireAttached();
      expect(rig.a.observed, isNotEmpty,
          reason: 'panel A observed no active set at all, so comparing the two '
              'sequences would be comparing two empty lists — vacuously equal '
              'and evidence for nothing');
      expect(rig.b.observed, rig.a.observed,
          reason: 'the two panels were told different things at some point in '
              'this run. Each entry is one ALARM.active payload as that panel '
              'decoded it off the wire, in order. An acknowledge applied to '
              'the CALLING SESSION\'s view of the set rather than to the '
              'engine would show up exactly here.'
              '\nA saw: ${rig.a.observed}'
              '\nB saw: ${rig.b.observed}');
    });

    // ------------------------------------------------------------------ 8 --
    test('arm 8: a backend RESTART does not put an acknowledged standing alarm '
        'back on every banner', () async {
      // A row a previous process left open, already acknowledged. Before this
      // plan the column was never written, so adoption had nothing to lose;
      // now it does.
      final seededId = await seedOpenRow(
        uid: kAlarmUid,
        ruleIndex: 0,
        createdAt: plantOnset,
        acknowledgedAt: backendNow,
      );

      // A "restart" here is a fresh composition — a fresh engine, a fresh
      // writer, a fresh gateway — over the SAME database. What the
      // reconciliation actually depends on is the state of the table and each
      // rule's first post-restart evaluation, and both are reproducible in one
      // process (14-06's argument, unchanged).
      final rig = await _Rig.standUp();
      rig.raise();
      await _waitUntil(
        () => rig.backend.engine!.acknowledgedStandingCount == 1,
        reason: () => 'the open row was never adopted as acknowledged. '
            '${rig.evidence()}',
      );
      await rig.backend.engine!.persistenceIdle();

      rig.requireAttached();
      expect(rig.a.uids, isEmpty,
          reason: 'the alarm an operator had already silenced came back on the '
              'banner after a restart, indistinguishable from nobody having '
              'pressed the button. ${rig.evidence()}');
      expect(rig.b.uids, isEmpty, reason: rig.evidence());

      final rows = await historyRows();
      expect(rows, hasLength(1),
          reason: 'adopting means inserting NOTHING — a second row is a plant '
              'that appears to have stopped twice for one fault. Got: $rows');
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull,
          reason: 'and the stop is still running');
      expect(parseStored(rows.single['acknowledged_at']), backendNow,
          reason: 'the acknowledgement the previous process recorded is the '
              'one that stands; re-stamping it would overwrite the instant '
              'somebody actually saw the alarm with the restart\'s');
    });
  });
}

// -------------------------------------------------------------------- fixture

AlarmManConfig _config() => AlarmManConfig(alarms: <AlarmConfig>[
      AlarmConfig(
        uid: kAlarmUid,
        title: 'Conveyor overspeed',
        description: 'CN01 is running above its commissioned limit',
        group: const <String>['Line 3', 'Pre-freezer'],
        rules: <AlarmRule>[
          AlarmRule(
            level: AlarmLevel.error,
            expression:
                ExpressionConfig(value: Expression(formula: '$kInputKey > 10')),
            acknowledgeRequired: false,
          ),
        ],
      ),
      AlarmConfig(
        uid: kHeldAlarmUid,
        title: 'Packer overspeed',
        description: 'CN04 is running above its commissioned limit',
        group: const <String>['Line 4'],
        rules: <AlarmRule>[
          AlarmRule(
            level: AlarmLevel.warning,
            expression: ExpressionConfig(
                value: Expression(formula: '$kHeldInputKey > 10')),
            // The whole of arm 5: this one is HELD on the banner after it
            // clears, waiting for somebody to say they saw it.
            acknowledgeRequired: true,
          ),
        ],
      ),
    ]);

/// One backend, a real socket, real Postgres, and two panels in front of it.
final class _Rig {
  _Rig._(this.fixture, this.a, this.b);

  final BackendRelayFixture fixture;

  ComposedBackendUnderTest get backend => fixture.backend;

  /// The panel that presses the button.
  final _Panel a;

  /// The panel that only watches — and must be told anyway.
  final _Panel b;

  static Future<_Rig> standUp() async {
    final fixture = backendRelayFixture(
      alarms: _config(),
      // Injected, fixed, and hours away from both plant instants, so
      // "the plant's time" and "the backend's time" can never be equal by
      // accident — the only condition under which arms 2, 4 and 5 could pass
      // for the wrong reason.
      clock: () => backendNow,
      // The real Postgres this file created, NOT the harness's shared SQLite:
      // `acknowledged_at` is a column, and a column's first write is not
      // something a different engine can be evidence about.
      store: (database: database, preferences: preferences),
      alarmHistory: AlarmHistoryWriter(database, logger: Logger(level: Level.off)),
      // Without one there is no view-role station in the world — the permissive
      // default answers `operate` for everybody. See [RoleTokenValidator].
      validator: const RoleTokenValidator(),
    );
    await fixture.ready;

    final a = await _Panel.attach(fixture.client, kOperateToken);
    final b = await _Panel.attach(await fixture.connectClient('B'), kOperateToken);
    return _Rig._(fixture, a, b);
  }

  /// A third session, speaking for a station that may look and not touch.
  Future<_Panel> joinViewOnly() async =>
      _Panel.attach(await fixture.connectClient('V'), kViewToken);

  /// Puts the conveyor over its limit, stamped by the plant.
  void raise() =>
      backend.harness.setValue(kInputKey, 42.0, sourceTime: plantOnset);

  /// Puts it back under, an hour later — still the plant's clock.
  void clear() =>
      backend.harness.setValue(kInputKey, 1.0, sourceTime: plantClear);

  void raiseHeld() =>
      backend.harness.setValue(kHeldInputKey, 42.0, sourceTime: plantOnset);

  void clearHeld() =>
      backend.harness.setValue(kHeldInputKey, 1.0, sourceTime: plantClear);

  /// Waits until both panels hold the conveyor alarm AND its row has been
  /// written, so an arm reading the row is not racing the INSERT.
  Future<void> awaitStanding() async {
    await _waitUntil(
      () => a.uids.contains(kAlarmUid) && b.uids.contains(kAlarmUid),
      reason: () => 'the activation never reached both panels. '
          '${evidence()}',
    );
    await backend.engine!.persistenceIdle();
  }

  Future<void> awaitSilenced() => _waitUntil(
        () => !a.uids.contains(kAlarmUid) && !b.uids.contains(kAlarmUid),
        reason: () => 'the acknowledge never took the alarm off both '
            'banners. ${evidence()}',
      );

  /// **The anti-vacuity check, and it is not decoration.**
  ///
  /// MEASURED, 14-11: with no heartbeat pump these sockets were reaped six
  /// seconds after their handshake, and an arm asserting "the panels agree"
  /// about two disconnected sockets passed because nobody was there to be told
  /// otherwise. Every arm here that claims something about what a panel holds
  /// calls this first.
  void requireAttached() {
    for (final panel in [a, b]) {
      expect(panel.client.closedByServer, isFalse,
          reason: '${panel.name} was disconnected before this arm made its '
              'claim, so whatever it is holding is what it was holding when '
              'the socket went — not what the backend last said. '
              '${evidence()}');
    }
  }

  String evidence() => 'backend: active=${backend.engine!.active.length}, '
      'acknowledgedStanding=${backend.engine!.acknowledgedStandingCount}, '
      'publications=${backend.engine!.publications}, '
      'evaluations=${backend.engine!.evaluations}, '
      'refusals=${backend.engine!.refusals}; '
      'inputs=${[
        for (final k in const [kInputKey, kHeldInputKey])
          '$k=${backend.composition.freshness.read(k)?.value}'
      ]}; '
      'A: ${a.describe()}; B: ${b.describe()}';
}

/// One panel: a socket, a session, one subscription, and everything it has been
/// told about the active set.
final class _Panel {
  _Panel._(this.client, this._snapshot, this._frames,
      this._heartbeatDeadlineMs);

  static Future<_Panel> attach(BackendRelayClient client, String token) async {
    final hello = await client.hello(token: token);
    // Listening BEFORE the subscribe goes out: an update that raced the answer
    // would otherwise be a frame nobody saw, and this panel's view would be
    // permanently one transition behind for a reason no arm names.
    final frames = <ServerNotification>[];
    final sub = client.notifications.listen(frames.add);
    addTearDown(sub.cancel);

    final result = await client.subscribe(kSub, <String>[relay.AlarmKeys.active]);
    return _Panel._(client, result, frames, hello.heartbeatDeadlineMs);
  }

  final BackendRelayClient client;
  final relay.SubscribeResult _snapshot;
  final List<ServerNotification> _frames;

  /// What the gateway advertised, never a literal.
  ///
  /// `relay_session.dart:1258-1271` is emphatic about this: a constant on the
  /// client that must match a server config nobody diffs fails silently a year
  /// later. Null when the gateway advertised nothing usable, and arm 0 refuses
  /// to proceed on a null.
  final int? _heartbeatDeadlineMs;

  Duration? get heartbeatDeadline => _heartbeatDeadlineMs == null
      ? null
      : Duration(milliseconds: _heartbeatDeadlineMs);

  String get name => 'panel ${client.name}';

  int? get _handle => _snapshot.handles[relay.AlarmKeys.active];

  List<relay.UpdateParams> get _updates => [
        for (final frame in _frames)
          if (frame.method == relay.Methods.update)
            relay.UpdateParams.fromJson(frame.params)
      ].where((u) => u.sub == kSub).toList();

  /// Every active set this panel has been told, in order: the subscribe
  /// answer's snapshot first, then one entry per `u` frame that moved the key.
  ///
  /// Rendered to a comparable signature rather than kept as objects, so arm 7's
  /// failure message names *what* differed instead of printing two lists of
  /// instance hashes.
  List<List<String>> get observed => <List<String>>[
        _signature(_snapshot.snapshot[_handle]?.v),
        for (final update in _updates)
          if (update.changes[_handle] != null)
            _signature(update.changes[_handle]!.v),
      ];

  static List<String> _signature(Object? payload) => <String>[
        for (final e in relay.AlarmActiveEntry.decodeList(payload).entries)
          '${e.uid}#${e.ruleIndex}@${e.activeAtMs}'
              '${e.pendingAck ? '!pendingAck' : ''}'
      ];

  /// The active set this panel currently holds, decoded off the wire.
  List<relay.AlarmActiveEntry> get entries {
    var value = _snapshot.snapshot[_handle]?.v;
    for (final update in _updates) {
      final changed = update.changes[_handle];
      if (changed != null) value = changed.v;
    }
    return relay.AlarmActiveEntry.decodeList(value).entries;
  }

  List<String> get uids => [for (final e in entries) e.uid];

  relay.AlarmActiveEntry? entryFor(String uid) {
    for (final entry in entries) {
      if (entry.uid == uid) return entry;
    }
    return null;
  }

  /// A live snapshot, and the fact that it is live is load-bearing.
  ///
  /// **Measured, this plan:** 14-11's `_waitUntil(reason: '…')` takes a STRING,
  /// so its evidence is rendered at the call site *before* the poll begins — a
  /// barrier that times out after twenty seconds then prints the rig as it was
  /// at second zero, which reads exactly like the rig as it was at second
  /// twenty. Under sabotage (h') that showed two panels with `beats=0` and made
  /// it look as though the heartbeat pump were dead. It is not; the reading was
  /// one second old. The barrier here takes a closure for that reason.
  String describe() => 'closedByServer=${client.closedByServer}, '
      'beats=${client.heartbeats}, handle=$_handle, '
      'entries=${[
        for (final e in entries)
          '${e.uid}#${e.ruleIndex}${e.pendingAck ? '(pendingAck)' : ''}'
      ]}, '
      'updates=${_updates.length}, frames=${client.inbound.length}';
}

/// Polls [condition] until it holds, or fails with [reason].
///
/// A `Stopwatch`, never two readings of `DateTime.now()`: this whole file is
/// about which clock produced which instant, and a backwards NTP step across a
/// poll would turn a passing barrier into a failure nobody could reproduce.
Future<void> _waitUntil(
  bool Function() condition, {
  required String Function() reason,
  Duration budget = const Duration(seconds: 20),
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > budget) fail(reason());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
