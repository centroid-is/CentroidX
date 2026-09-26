@TestOn('vm')

/// Two ceilings on what one frame may make the gateway do, both found by
/// adversarial review and both refused before anything is graded:
///
///  * a JSON-RPC **batch** longer than [RelaySession.maxBatchRequests] —
///    every member of a pre-hello batch was answered with a gate refusal
///    carrying the substitute text, ~8× the request's size into the priority
///    lane;
///  * a `preferences.clear` naming more than [kPreferenceClearCeiling] keys —
///    every key becomes an audit row, so one frame became tens of thousands
///    of sink inserts.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart'
    show FakePreferences;
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

final class _RecordingSink implements AuditSink {
  final rows = <AuditRecord>[];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

void main() {
  group('a batch frame is bounded', () {
    late StreamChannel<String> wire;
    late List<Object?> answers;

    setUp(() {
      final pair = channelPair();
      final api = FakeStateMan();
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: api,
        config: ServerConfig(),
        handles: HandleTable(),
        buffer: ConflatingSendBuffer(maxPending: 4096),
        onError: (_, __, ___) {},
      );
      addTearDown(() async {
        await session.close(1000, 'test over');
        await api.dispose();
      });
      wire = pair.client;
      answers = [];
      wire.stream.listen((frame) => answers.add(jsonDecode(frame)));
    });

    String ping(int i) =>
        '{"jsonrpc":"2.0","id":"b$i","method":"${Methods.ping}","params":{}}';

    Future<void> untilAnswered(String what) => within(
        Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return answers.isEmpty;
        }),
        what);

    test('one over the ceiling is refused whole, sourcelessly, and the '
        'session survives', () async {
      final n = RelaySession.maxBatchRequests + 1;
      wire.sink.add('[${List.generate(n, ping).join(',')}]');
      await untilAnswered('the refusal of an over-long batch');

      final answer = answers.single;
      expect(answer, isA<Map>(),
          reason: 'ONE frame back, not $n gate refusals');
      final error = ((answer as Map)['error'] as Map);
      expect(error['code'], rpc_errors.PARSE_ERROR);
      expect('$error', isNot(contains('b0')),
          reason: 'sourceless: the refusal must not echo the batch');

      // Still answering: the ceiling cost one frame, not the socket.
      answers.clear();
      wire.sink.add(ping(0));
      await untilAnswered('a ping after the refused batch');
      expect(answers.single, isA<Map>());
    });

    test('a batch under the ceiling is dispatched as a batch', () async {
      wire.sink.add('[${ping(0)},${ping(1)}]');
      await untilAnswered('the batch answer');
      expect(answers.single, isA<List>(),
          reason: 'a legitimate batch is still a batch');
      expect((answers.single as List), hasLength(2));
    });
  });

  group('preferences.clear is bounded', () {
    PolicyStateMan served(_RecordingSink sink) => PolicyStateMan(
          source: FakeStateMan(preferences: FakePreferences()),
          policy: const AccessPolicyKeyPolicy(),
          resolver: const PermissiveSeriesResolver(),
          tally: SeriesMappingTally(),
          identityOf: () => stationHolding(AccessGroup.values.toSet()),
          sink: sink,
        );

    test('one key over the ceiling is refused pre-effect, with no row',
        () async {
      final sink = _RecordingSink();
      final api = served(sink);
      final keys = {
        for (var i = 0; i <= kPreferenceClearCeiling; i++) 'svn.flood.$i'
      };
      // A closure: the refusal is pre-effect and synchronous — it is thrown
      // by the call itself, before any future exists to await.
      await expectLater(
          () => api.preferences.clear(allowList: keys),
          throwsA(isA<rpc.RpcException>()
              .having((e) => e.code, 'code', rpc_errors.INVALID_PARAMS)));
      expect(sink.rows, isEmpty,
          reason: 'the flood is what the ceiling exists to prevent');
    });

    test('at the ceiling it still clears — the bound is not a refusal of '
        'clearing', () async {
      final sink = _RecordingSink();
      final api = served(sink);
      final keys = {
        for (var i = 0; i < kPreferenceClearCeiling; i++) 'svn.ok.$i'
      };
      await api.preferences.clear(allowList: keys);
      expect(sink.rows.where((r) => r.allowed), hasLength(keys.length));
    });
  });
}
