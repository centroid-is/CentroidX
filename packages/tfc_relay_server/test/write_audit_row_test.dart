@TestOn('vm')

/// Every hand-made write recorded (access spec §2), over the wire.
///
/// Until the fix this file pins, the relay's `write` handler graded a tag
/// write through `PolicyStateMan.canWrite` and never recorded it — allowed or
/// refused — and `ackAlarm`, which asks the same question about
/// `AlarmKeys.active`, left nothing either. The trail was the only record,
/// and it could not show that anybody moved a setpoint over the wire. Found
/// where it would be seen: `test/e2e_pages/pages/audit_trail.dart`.
///
/// Two layers. The first half asks the decorator directly, the way the
/// handlers do, and pins the row's every column. The second half drives a
/// `write` and an `ackAlarm` through a real session over an in-memory
/// channel, so the rows are proven to come from the handlers' one call and
/// not from a test asking a question the wire never asks.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

const _key = 'HALL1.CN01.setpoint_kg';

final class _RecordingSink implements AuditSink {
  final rows = <AuditRecord>[];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// The decorator as `RelaySession` builds it, with the identity a lever.
PolicyStateMan _served(StationIdentity? identity, _RecordingSink sink) =>
    PolicyStateMan(
      source: FakeStateMan(),
      policy: const AccessPolicyKeyPolicy(),
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => identity,
      sink: sink,
      station: 'gateway-host',
    );

final _operator = stationHolding(const {AccessGroup.operate},
    station: 'ST101', username: 'ST101-panel', roleName: 'Line Panel');
final _viewer = stationHolding(const {},
    station: 'HALL-DISPLAY', username: 'display', roleName: 'Hall Display');

void main() {
  group('PolicyStateMan.canWrite leaves the verdict as a row', () {
    test('an allowed write: one tag row, every column the keyboard path '
        'writes', () {
      final sink = _RecordingSink();
      final api = _served(_operator, sink);

      expect(api.canWrite(_key, members: kWholeKeyWrite), isTrue);

      final row = sink.rows.single;
      expect(row.surface, AccessSurface.tag.wireName);
      expect(row.itemKey, _key);
      expect(row.member, isNull);
      expect(row.allowed, isTrue);
      expect(row.groupRequired, AccessGroup.operate.name,
          reason: 'the floor every tag write is graded at');
      expect(row.who, 'ST101-panel');
      expect(row.station, 'ST101');
      expect(row.roleName, 'Line Panel');
      expect(row.origin, 'relay',
          reason: 'a row the gateway wrote must never read as one a panel '
              'wrote about itself');
      expect(row.actionId, isNotEmpty);
    });

    test('a refused write: the deny row, before the caller is told', () {
      final sink = _RecordingSink();
      final api = _served(_viewer, sink);

      expect(api.canWrite(_key, members: kWholeKeyWrite), isFalse);

      final row = sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.who, 'display');
      expect(row.groupRequired, AccessGroup.operate.name);
    });

    test('a struct write names every member it moves, under one action',
        () {
      final sink = _RecordingSink();
      final api = _served(_operator, sink);

      api.canWrite(_key, members: const ['setpoint', 'mode']);

      expect(sink.rows.map((r) => r.member), ['setpoint', 'mode']);
      expect(sink.rows.map((r) => r.actionId).toSet(), hasLength(1),
          reason: 'one press, one action, however many members it moved');
    });

    test('no members named is the whole-key question, and one row', () {
      final sink = _RecordingSink();
      final api = _served(_operator, sink);

      api.canWrite(_key, members: const []);

      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.member, isNull);
    });

    test('two verdicts are two actions — the id is minted, never shared',
        () {
      final sink = _RecordingSink();
      final api = _served(_operator, sink);

      api.canWrite(_key, members: kWholeKeyWrite);
      api.canWrite(_key, members: kWholeKeyWrite);

      expect(sink.rows.map((r) => r.actionId).toSet(), hasLength(2));
    });

    test('before hello there is no identity, and the row says so', () {
      final sink = _RecordingSink();
      final api = _served(null, sink);

      expect(api.canWrite(_key, members: kWholeKeyWrite), isFalse);

      final row = sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.who, 'anonymous');
      expect(row.station, 'gateway-host',
          reason: 'the ledger\'s fallback for a verdict with no identity');
    });

    test('a sink that throws changes no verdict', () {
      final api = PolicyStateMan(
        source: FakeStateMan(),
        policy: const AccessPolicyKeyPolicy(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => _operator,
        sink: _ThrowingSink(),
        onAuditError: (_, __, ___) {},
      );
      expect(api.canWrite(_key, members: kWholeKeyWrite), isTrue);
    });
  });

  group('over the wire', () {
    test('a write the plant executes leaves an allow row for its key',
        () async {
      final sink = _RecordingSink();
      final link = await _Link.open(_operator, sink);
      final before = sink.rows.length;

      final answer = await link.call(Methods.write, {
        'cmd': 'cmd-1',
        'key': _key,
        'value': 13.5,
      });
      expect(answer, isA<Map>());

      final rows = sink.rows.skip(before).where((r) => r.itemKey == _key);
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isTrue);
      expect(rows.single.surface, AccessSurface.tag.wireName);
      expect(rows.single.who, 'ST101-panel');
    });

    // Two refusals, two rows. The gate's: an operate-holding station against
    // a policy that sees everything and writes nothing
    // (`ScriptedPolicy.readOnly`), so the read floor passes, the existence
    // check passes, and the write GATE refuses. The floor's: a station
    // holding no group at all, turned away one step earlier — a hand-made
    // write refused all the same, and recorded under the floor's own group.
    test('a write the gate refuses leaves a deny row', () async {
      final sink = _RecordingSink();
      final link =
          await _Link.open(_operator, sink, policy: ScriptedPolicy.readOnly());
      final before = sink.rows.length;

      await expectLater(
          link.call(Methods.write, {'cmd': 'cmd-2', 'key': _key, 'value': 1}),
          throwsA(isA<rpc.RpcException>()));

      final rows = sink.rows.skip(before).where((r) => r.itemKey == _key);
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isFalse);
      expect(rows.single.who, 'ST101-panel');
    });

    test('an alarm acknowledge — refused here, for want of an engine — still '
        'left its verdict row', () async {
      // The gateway is composed without an alarm engine, so the ack is
      // refused by name after the gate. The gate's row is the point: the
      // decision about `AlarmKeys.active` was made and must be findable.
      final sink = _RecordingSink();
      final link = await _Link.open(_operator, sink);
      final before = sink.rows.length;

      await expectLater(
          link.call(Methods.ackAlarm,
              AckAlarmParams(alarmUid: 'ALM-01', ruleIndex: 0).toJson()),
          throwsA(isA<rpc.RpcException>()));

      final rows = sink.rows
          .skip(before)
          .where((r) => r.itemKey == AlarmKeys.active)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isTrue,
          reason: 'the station holds operate; the refusal came from the '
              'missing engine, not from the policy');
      expect(rows.single.surface, AccessSurface.tag.wireName);
    });

    test('a write refused at the read floor — a session holding nothing — '
        'leaves a deny row under the floor\'s group', () async {
      final sink = _RecordingSink();
      final link = await _Link.open(_viewer, sink);
      final before = sink.rows.length;

      await expectLater(
          link.call(Methods.write, {'cmd': 'cmd-3', 'key': _key, 'value': 1}),
          throwsA(isA<rpc.RpcException>()));

      final rows =
          sink.rows.skip(before).where((r) => r.itemKey == _key).toList();
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isFalse);
      expect(rows.single.who, 'display');
      expect(rows.single.groupRequired, plantReadFloor.name);
    });

    test('an acknowledge refused at the read floor leaves a deny row too',
        () async {
      final sink = _RecordingSink();
      final link = await _Link.open(_viewer, sink);
      final before = sink.rows.length;

      await expectLater(
          link.call(Methods.ackAlarm,
              AckAlarmParams(alarmUid: 'ALM-01', ruleIndex: 0).toJson()),
          throwsA(isA<rpc.RpcException>()));

      final rows = sink.rows
          .skip(before)
          .where((r) => r.itemKey == AlarmKeys.active)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isFalse);
    });

    test('a read refused at the read floor leaves NO row — the trail is not '
        'buried in a display\'s re-subscribes', () async {
      final sink = _RecordingSink();
      final link = await _Link.open(_viewer, sink);
      final before = sink.rows.length;

      await expectLater(link.call(Methods.read, {'key': _key}),
          throwsA(isA<rpc.RpcException>()));

      expect(sink.rows.skip(before), isEmpty);
    });

    test('an acknowledge the gate refuses leaves a deny row', () async {
      final sink = _RecordingSink();
      final link =
          await _Link.open(_operator, sink, policy: ScriptedPolicy.readOnly());
      final before = sink.rows.length;

      await expectLater(
          link.call(Methods.ackAlarm,
              AckAlarmParams(alarmUid: 'ALM-01', ruleIndex: 0).toJson()),
          throwsA(isA<rpc.RpcException>()));

      final rows = sink.rows
          .skip(before)
          .where((r) => r.itemKey == AlarmKeys.active)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isFalse);
    });
  });
}

final class _ThrowingSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) => throw StateError('trail down');
}

final class _AlwaysStation implements TokenValidator {
  const _AlwaysStation(this.identity);
  final StationIdentity identity;
  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}

/// One session over an in-memory channel — `alarm_ack_test.dart:_link`, with
/// the sink threaded in and the plant seeded with the two keys the arms
/// write to.
final class _Link {
  _Link(this.session, this.client, this.api);

  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  static Future<_Link> open(StationIdentity identity, AuditSink sink,
      {KeyPolicy policy = const AccessPolicyKeyPolicy()}) async {
    final pair = channelPair();
    final api = FakeStateMan();
    api.setValue(_key, 12.0);
    api.setValue(AlarmKeys.active, const <Object?>[]);
    final session = RelaySession.serve(
      resolver: const PermissiveSeriesResolver(),
      channel: pair.server,
      api: api,
      config: ServerConfig(),
      handles: HandleTable(),
      buffer: ConflatingSendBuffer(maxPending: 4096),
      validator: _AlwaysStation(identity),
      policy: policy,
      audit: sink,
      serverSupported: const [protocolVersion],
      onError: (_, __, ___) {},
    );
    final client = rpc.Client(pair.client);
    unawaited(client.listen());
    final link = _Link(session, client, api);
    addTearDown(link.dispose);
    await within(
        client.sendRequest(
            Methods.hello,
            HelloParams(
              protocol: protocolVersion,
              supported: const [protocolVersion],
              client: const PeerInfo('panel-under-test', '0.1.0'),
            ).toJson()),
        'the hello result');
    return link;
  }

  Future<Object?> call(String method, Map<String, Object?> params) =>
      within(client.sendRequest(method, params), 'a $method answer');

  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'audit row test over');
    await api.dispose();
  }
}
