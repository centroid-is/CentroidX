@TestOn('vm')

/// **Alarm history, on the gateway.**
///
/// ## What was broken
///
/// `RelayAlarmSource.getRecentAlarms` read the panel's own database, under a
/// ruling (D-11) whose premise was that a gateway-mode panel has one.
/// `lib/providers/preferences.dart:60` now branches on the transport before it
/// reads the config row, so a gateway panel builds `Preferences` with
/// `db: null` and `if (preferences.database == null) return []` became the only
/// branch that ever runs. The plant symptom is not an error: it is a history
/// page that looks like a factory which has never had an alarm.
///
/// ## Why this is gated differently from the acknowledge
///
/// `alarm_ack_test.dart` pins the ack to the session's `canWrite` answer,
/// because an acknowledge is an operator action that clears something off
/// everybody's banner. **Reading history is a read**, and this file pins it to
/// the *visibility* answer instead — whether the station may see
/// `AlarmKeys.active` at all, which is the same question every other read on
/// this wire is gated by and the same one that decides whether the station gets
/// a banner in the first place.
///
/// That difference is a decision and it has an arm of its own (`a view station
/// may read history`). Getting it wrong in the tightening direction is not
/// safe-by-default: it would blank the history page on the canteen wall display
/// and on every `view` station in the plant, which is the same silent empty
/// page this whole change exists to remove — arrived at through a permission
/// instead of through a missing database.
///
/// There is deliberately **no second policy object** here. The handler is
/// handed the session's own `PolicyStateMan` view, exactly as `AlarmHandlers`
/// already is for the ack, so a policy change moves every alarm surface at once.
///
/// ## The arm that matters most
///
/// `a source that fails is a refusal, never an empty history`. Every other way
/// this can go wrong is loud. That one is the failure class the whole milestone
/// is about: an empty list is what a quiet plant looks like, so a handler that
/// swallows its source's exception has told the operator a fact about the
/// factory when it only had a fact about the gateway.
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/alarm_history_source.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';

/// `alarm_ack_test.dart`'s two stations, in its spelling, because they model
/// the same two things: a panel beside a machine that holds `operate`, and a
/// display on a wall that holds nothing.
const _panelUser = AuthenticatedUser(
    username: 'ST101-panel', roleName: 'Panel Operator', stationAccount: true);
const _displayUser = AuthenticatedUser(
    username: 'HALL-DISPLAY-panel',
    roleName: 'Hall Display',
    stationAccount: true);

const _panel = StationIdentity(
    user: _panelUser,
    station: 'ST101',
    session: AccessSession(user: _panelUser, groups: {AccessGroup.operate}));
const _display = StationIdentity(
    user: _displayUser,
    station: 'HALL-DISPLAY',
    session: AccessSession(user: _displayUser, groups: {}));

AlarmHistoryEntry _row({
  String uid = 'CN04.MOT01',
  int? ruleIndex = 1,
  bool active = false,
}) =>
    AlarmHistoryEntry(
      uid: uid,
      ruleIndex: ruleIndex,
      level: 'error',
      title: 'Motor overload',
      description: 'the drive tripped',
      group: const ['Line 3'],
      expression: 'a{10.0} > 5',
      acknowledgeRequired: true,
      active: active,
      createdAt: DateTime.utc(2026, 9, 8, 19, 18, 3),
      deactivatedAt: active ? null : DateTime.utc(2026, 9, 8, 19, 22, 3),
      tsSource: AlarmActiveEntry.tsSourcePlant,
    );

/// A history reader that writes down what it was asked for.
///
/// `_Recorder` in `alarm_ack_test.dart`, and the recorded arguments carry more
/// weight here: the query has *parameters*, and a handler that dropped the
/// window or clamped the limit would answer a different question confidently.
final class _Recorder implements AlarmHistorySource {
  _Recorder({this.rows = const [], this.failWith});

  final List<AlarmHistoryEntry> rows;

  /// What this reader throws instead of answering. A database that is down is
  /// the case being modelled, and the arm it serves is the one this file exists
  /// for.
  final Object? failWith;

  final queries = <({int limit, DateTime? from, DateTime? to})>[];

  @override
  Future<List<AlarmHistoryEntry>> recentAlarms({
    required int limit,
    DateTime? from,
    DateTime? to,
  }) async {
    queries.add((limit: limit, from: from, to: to));
    if (failWith != null) throw failWith!;
    return rows;
  }
}

/// The shipped policy, with a hiding set. `alarm_ack_test.dart:_SpyPolicy`,
/// trimmed to what this file asks of it.
final class _SpyPolicy implements KeyPolicy {
  _SpyPolicy({this.hidden = const {}});

  final Set<String> hidden;

  /// Every key `canWrite` was asked about. Expected to stay **empty**: a read
  /// that consults the write gate is a read a `view` station cannot make.
  final askedToWrite = <String>[];

  @override
  bool canSee(String key, StationIdentity identity) => !hidden.contains(key);

  @override
  bool canWrite(String key, StationIdentity identity) {
    askedToWrite.add(key);
    if (hidden.contains(key)) return false;
    return identity.session.can(AccessGroup.operate);
  }

  @override
  bool canWritePreference(String key, StationIdentity identity) =>
      !hidden.contains(key) && identity.session.can(AccessGroup.operate);
}

final class _AlwaysStation implements TokenValidator {
  const _AlwaysStation(this.identity);

  final StationIdentity identity;

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}

final class _Link {
  _Link(this.session, this.client, this.api);

  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'history test over');
    await api.dispose();
  }

  Future<Object?> hello() => within(
      client.sendRequest(
          Methods.hello,
          HelloParams(
            protocol: protocolVersion,
            supported: const [protocolVersion],
            client: const PeerInfo('panel-under-test', '0.1.0'),
          ).toJson()),
      'the hello result');

  Future<Object?> history({int limit = 100, DateTime? from, DateTime? to}) =>
      within(
          client.sendRequest(
              Methods.alarmHistory,
              AlarmHistoryParams(limit: limit, from: from, to: to).toJson()),
          'an alarmHistory response');

  /// Sends [params] raw, so a frame the DTO would refuse to build can still be
  /// put on the wire.
  Future<Object?> historyRaw(Map<String, Object?> params) => within(
      client.sendRequest(Methods.alarmHistory, params),
      'an alarmHistory response to a raw frame');
}

_Link _link({
  StationIdentity identity = _panel,
  KeyPolicy? policy,
  AlarmHistorySource? alarmHistory,
  bool seedActive = true,
}) {
  final pair = channelPair();
  final api = FakeStateMan();
  // `FakeStateMan.keys` only offers a key that has a value, so the existence
  // check has something to find — 14-03 put `AlarmKeys.active` in
  // `BackendLiveValues.keys`, which is what makes it pass in the plant.
  if (seedActive) api.setValue(AlarmKeys.active, const <Object?>[]);
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: _AlwaysStation(identity),
    policy: policy ?? const AccessPolicyKeyPolicy(),
    alarmHistory: alarmHistory,
    serverSupported: const [protocolVersion],
    onError: (_, __, ___) {},
  );
  final client = rpc.Client(pair.client);
  unawaited(client.listen());
  final link = _Link(session, client, api);
  addTearDown(link.dispose);
  return link;
}

Future<rpc.RpcException> _refused(Future<Object?> call, String what) async {
  try {
    await call;
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

void main() {
  test('a station gets the rows the source held, decodable as history',
      () async {
    final source = _Recorder(rows: [_row(), _row(uid: 'CN05.MOT01')]);
    final link = _link(alarmHistory: source);
    await link.hello();

    final answer = await link.history();

    expect(AlarmHistoryEntry.decodeList(answer), source.rows,
        reason: 'the answer decodes through the same function the client uses, '
            'so a shape only this test can read is not a passing shape');
  });

  test('a plant with no history answers an empty list, and it is legible',
      () async {
    // The one case that must stay representable. An empty history is a real
    // fact and the wire has to be able to state it — what must never happen is
    // that fact being *invented* from a failure, which is the arm below.
    final link = _link(alarmHistory: _Recorder());
    await link.hello();

    expect(AlarmHistoryEntry.decodeList(await link.history()), isEmpty);
  });

  test('a source that fails is a refusal, never an empty history', () async {
    // **The arm this file exists for.** Swallowing the exception and answering
    // `{entries: []}` would tell an operator the plant has had no alarms
    // because the gateway could not reach its database — a fact about the
    // gateway, reported as a fact about the factory, with nothing on screen to
    // say so.
    final link = _link(
        alarmHistory: _Recorder(
            failWith: StateError('alarm_history is unreachable: no pool')));
    await link.hello();

    final refusal =
        await _refused(link.history(), 'history from a failing source');

    expect(refusal.code, ServerErrorCodes.handlerFailed);
  });

  test('the window and the limit reach the source verbatim', () async {
    // Not defaulted, not clamped, not dropped. A handler that lost the window
    // would answer the newest N rows to a stop timeline asking about last
    // Tuesday, and the chart would be confidently wrong rather than empty.
    final source = _Recorder();
    final link = _link(alarmHistory: source);
    await link.hello();

    await link.history(
      limit: 2000,
      from: DateTime.utc(2026, 9, 1, 6),
      to: DateTime.utc(2026, 9, 1, 14),
    );

    expect(source.queries, [
      (
        limit: 2000,
        from: DateTime.utc(2026, 9, 1, 6),
        to: DateTime.utc(2026, 9, 1, 14)
      )
    ]);
    expect(source.queries.single.from!.isUtc, isTrue,
        reason: 'a bound reconstructed through the gateway\'s local time zone '
            'is a window that means something different on every machine');
  });

  test('an unbounded window arrives as two nulls, not as an invented window',
      () async {
    final source = _Recorder();
    final link = _link(alarmHistory: source);
    await link.hello();

    await link.history(limit: 10);

    expect(source.queries.single.from, isNull);
    expect(source.queries.single.to, isNull);
  });

  test('a view station may read history', () async {
    // The deliberate difference from `alarm_ack_test.dart`. Gating this on
    // `canWrite` would blank the history page on every `view` station in the
    // plant — the same empty page this change exists to remove, reached
    // through a permission instead of through a missing database.
    final policy = _SpyPolicy();
    final source = _Recorder(rows: [_row()]);
    final link =
        _link(identity: _display, policy: policy, alarmHistory: source);
    await link.hello();

    expect(AlarmHistoryEntry.decodeList(await link.history()), hasLength(1));
    expect(policy.askedToWrite, isEmpty,
        reason: 'a read that consults the write gate is a read a view station '
            'cannot make, and this is the assertion that catches it — the '
            'answer above would still be right if the display happened to '
            'hold operate');
  });

  test('a hidden ALARM.active is refused as nonexistent, never as forbidden',
      () async {
    // `alarm_ack_test.dart`'s ordering arm, and the same disclosure:
    // answering `forbidden` says the key exists, which is the enumeration
    // `key_policy.dart:16-26` conceals.
    final source = _Recorder(rows: [_row()]);
    final link = _link(
        policy: _SpyPolicy(hidden: {AlarmKeys.active}), alarmHistory: source);
    await link.hello();

    final refusal =
        await _refused(link.history(), 'history for a hidden key');

    expect(refusal.code, rpc_errors.INVALID_PARAMS);
    expect(refusal.code, isNot(ServerErrorCodes.forbidden));
    expect(source.queries, isEmpty,
        reason: 'a gate that refuses after reading has already read');
  });

  test('a gateway with no history source refuses by name', () async {
    final link = _link();
    await link.hello();

    final refusal = await _refused(
        link.history(), 'history on a gateway with no source');

    expect(refusal.code, isNot(rpc_errors.METHOD_NOT_FOUND),
        reason: '"serves no alarm history" and "too old to know the word" are '
            'fixed in different places, so they must be different answers');
    expect(refusal.message, contains('AlarmHistorySource'),
        reason: 'the missing collaborator, named, so the sentence says what '
            'to change');
  });

  test('malformed params are refused before the source is reached', () async {
    final source = _Recorder(rows: [_row()]);
    final link = _link(alarmHistory: source);
    await link.hello();

    final refusal = await _refused(
        link.historyRaw(const {}), 'a history query stating no limit');

    expect(refusal.code, rpc_errors.INVALID_PARAMS);
    expect(source.queries, isEmpty);
  });

  test('a limit above the wire ceiling is refused, never clamped', () async {
    final source = _Recorder(rows: [_row()]);
    final link = _link(alarmHistory: source);
    await link.hello();

    final refusal = await _refused(
        link.historyRaw({'limit': AlarmHistoryParams.maxLimit + 1}),
        'a history query over the ceiling');

    expect(refusal.code, rpc_errors.INVALID_PARAMS);
    expect(source.queries, isEmpty,
        reason: 'clamping would answer a short history as the whole one');
  });

  test('the refusal echoes no request back', () async {
    // `value_handlers.dart:_refuse`'s armour: `RpcException.serialize` copies
    // the offending request into `error.data` when it is not pre-substituted,
    // and one request carrying `1e999` then makes the *error* unencodable — at
    // which point the peer drops it and a caller without a deadline waits
    // forever.
    final link = _link(alarmHistory: _Recorder());
    await link.hello();

    final refusal = await _refused(
        link.historyRaw(const {'limit': 0}), 'a zero-row history query');

    expect(refusal.data, isA<Map<String, Object?>>());
    expect((refusal.data! as Map)['method'], Methods.alarmHistory);
    expect((refusal.data! as Map)['request'], isNot(const {'limit': 0}));
  });

  test('a history query before hello is refused and nothing is read',
      () async {
    final source = _Recorder(rows: [_row()]);
    final link = _link(alarmHistory: source);

    final refusal = await _refused(link.history(), 'a pre-hello history query');

    expect(refusal.code, ServerErrorCodes.helloRequired);
    expect(source.queries, isEmpty);
  });

  test('alarmHistory is registered whether or not a source was supplied',
      () async {
    // A wire surface that varies by deployment is a surface no literal can
    // freeze, and it is what would make `-32601` mean two different things.
    expect(_link(alarmHistory: null).session.registeredMethods,
        contains(Methods.alarmHistory));
    expect(_link(alarmHistory: _Recorder()).session.registeredMethods,
        contains(Methods.alarmHistory));
  });
}
