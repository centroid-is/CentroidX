/// The session's front door: what a client may do before it has said hello,
/// what a hello buys it, and what a request that cannot be answered does.
///
/// Driven over `channelPair()` — an in-memory `StreamChannel<String>` with a
/// real `json_rpc_2` client on the far end and no sockets anywhere. The socket
/// is 03-04's subject; every property below is a property of the session, and
/// a property that needs a port to be asserted is a property that gets
/// asserted rarely.
///
/// Two of these cases are the verification of something research could only
/// mark [ASSUMED] or measure once:
///
///  * **Pre-hello rejection.** 03-CONTEXT rules that gating lives in the
///    handler wrapper rather than in `registerFallback`, whose behaviour is
///    untested upstream. The wrapper either gates or it does not, and the case
///    below is how we know which.
///  * **The 02-05 hang.** `RpcException.serialize` copies the offending
///    request into `error.data` unless `data['request']` is already set. One
///    request carrying `1e999` decodes to `Infinity`, the error response
///    becomes unencodable, the peer drops it, and a caller with no deadline
///    waits forever. The case below asserts a *bool derived from a deadline*
///    rather than waiting on a matcher, for the reason
///    `malformed_peer_test.dart:1-33` gives: a matcher that waits for
///    something that never happens reports this file's name instead of the
///    broken property.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/permissive_resolver.dart';

/// One session, one client, both wired and listening.
final class _Link {
  _Link(this.session, this.client, this.api);
  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  /// Everything this session started, stopped. The fake keeps a periodic
  /// freshness sweep running, and a timer left behind by a finished case is
  /// the leak class F23 exists to catch.
  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'test over');
    await api.dispose();
  }
}

_Link _link(
    {TokenValidator? validator,
    List<String>? serverSupported,
    ServerConfig? config}) {
  final pair = channelPair();
  final api = FakeStateMan();
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: config ?? ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: validator ?? const PermissiveTokenValidator(),
    serverSupported: serverSupported ?? const [protocolVersion],
  );
  final client = rpc.Client(pair.client);
  unawaited(client.listen());
  return _Link(session, client, api);
}

Map<String, Object?> _hello({List<String>? supported}) => HelloParams(
      protocol: supported?.first ?? protocolVersion,
      supported: supported ?? const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
    ).toJson();

/// Sends [method] expecting a refusal, and hands back the refusal.
Future<rpc.RpcException> _refusal(
    Future<Object?> call, String what) async {
  try {
    await within(call, what);
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

/// A validator that turns every client away, standing in for Phase 6's.
final class _RejectingValidator implements TokenValidator {
  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      const TokenRejected('no credential presented');
}

void main() {
  test('a request before hello is refused and the link stays open', () async {
    final link = _link();
    addTearDown(link.dispose);

    // `ping`, because it is one of the two methods that exist today; 03-05's
    // `subscribe` will be gated by the same wrapper without touching it, which
    // is the point of gating at the registration seam rather than per handler.
    final refusal =
        await _refusal(link.client.sendRequest(Methods.ping), 'a pre-hello ping');

    expect(refusal.code, ServerErrorCodes.helloRequired,
        reason: 'an unauthenticated client must be told what is missing, not '
            'served');
    expect((refusal.data as Map)['request'], isA<String>(),
        reason: 'even a refusal must carry the substituted request, or the '
            'refusal itself is unencodable when the request was poison');

    final result = await within(
        link.client.sendRequest(Methods.hello, _hello()), 'a hello after the '
            'refusal');
    expect(HelloResult.fromJson((result as Map).cast()).protocol,
        protocolVersion,
        reason: 'a pre-hello request is refused *without closing* (Home '
            'Assistant\'s pre-auth rule): the client gets to correct itself');
  });

  test('a valid hello negotiates a version and opens a session', () async {
    final link = _link();
    addTearDown(link.dispose);
    final before = DateTime.now().millisecondsSinceEpoch;

    final raw = await within(
        link.client.sendRequest(Methods.hello, _hello()), 'the hello result');
    final result = HelloResult.fromJson((raw as Map).cast());

    expect(result.protocol, protocolVersion);
    expect(result.sessionId, isNotEmpty);
    expect(result.epoch, isNotEmpty);
    // The `session` object this gateway emits, asserted key for key.
    //
    // This replaces `expect(result.resumed, isFalse)`: 16-11 withdrew the
    // resume surface (HARD-03), so there is no longer a field to read. It is
    // written as an exact key set rather than as "does not contain `resumed`"
    // on purpose — a bare absence assertion is satisfied by a `session` object
    // that has gone missing altogether, which is the *other* way this deletion
    // could have been wrong and the one that breaks every reconnection in the
    // plant. Naming both surviving keys makes the arm fail in both directions.
    final session = (raw['session'] as Map).cast<String, Object?>();
    expect(session.keys, unorderedEquals(<String>['id', 'epoch']),
        reason: 'the hello response emitted ${session.keys.toList()}. `id` and '
            '`epoch` are load-bearing — the client feeds `epoch` straight into '
            'ResyncEngine.onHello, and `id` is what server-side attribution is '
            'written against. `resumed` is not: honouring it meant retaining '
            'subscription state across a socket loss and replaying from a '
            'per-subscription sequence, which is delta replay, and this '
            'product resyncs by snapshot (CLAUDE.md). It was hardcoded false '
            'for eleven phases, and a client told its cache survived when it '
            'did not shows stale plant data under a healthy-looking link');
    expect(result.serverTime,
        inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch),
        reason: 'the client derives its clock offset from this, so staleness '
            'is measured against one clock');

    final other = _link();
    addTearDown(other.dispose);
    final second = HelloResult.fromJson(
        ((await within(other.client.sendRequest(Methods.hello, _hello()),
                'a second session\'s hello')) as Map)
            .cast());
    expect(second.sessionId, isNot(result.sessionId),
        reason: 'two sessions sharing an id merge in every log the gateway '
            'writes');
  });

  test('a second hello on the same session is refused', () async {
    final link = _link();
    addTearDown(link.dispose);
    await within(
        link.client.sendRequest(Methods.hello, _hello()), 'the first hello');

    final refusal = await _refusal(
        link.client.sendRequest(Methods.hello, _hello()), 'a second hello');
    expect(refusal.code, ServerErrorCodes.alreadyHelloed);

    expect(await within(link.client.sendRequest(Methods.ping), 'a ping after '
        'the refused second hello'), isA<Map>(),
        reason: 'a renegotiation attempt is a client bug, not a hostile act: '
            'the session it already has keeps working');
    expect(link.session.sentCloseCode, isNull);
  });

  test('an unspeakable version records 4005 with both lists', () async {
    final link = _link();
    addTearDown(link.dispose);

    final refusal = await _refusal(
        link.client
            .sendRequest(Methods.hello, _hello(supported: ['1999-01-01'])),
        'a hello naming a version the server cannot speak');

    expect(refusal.code, ServerErrorCodes.versionMismatch);
    final data = (refusal.data as Map).cast<String, Object?>();
    expect(data['supported'], contains(protocolVersion));
    expect(data['requested'], contains('1999-01-01'),
        reason: 'both lists, MCP\'s rule: a client that is told only "no" has '
            'nothing to log and nothing to fix');

    expect(link.session.sentCloseCode, CloseCodes.protocolMismatch,
        reason: 'asserted on the session\'s own record, never on a socket\'s '
            'closeCode — that field is unreliable for a self-initiated close '
            '(web_socket_channel #1698)');
  });

  test('a rejected credential refuses hello and records 4001', () async {
    final link = _link(validator: _RejectingValidator());
    addTearDown(link.dispose);

    final refusal = await _refusal(
        link.client.sendRequest(Methods.hello, _hello()),
        'a hello with a credential the validator rejects');

    expect(refusal.code, ServerErrorCodes.unauthorized);
    expect(link.session.sentCloseCode, CloseCodes.authExpired);
  });

  test('a handler throwing on a request carrying 1e999 still delivers an error',
      () async {
    // Hand-written frame: `jsonEncode` refuses to emit Infinity, so a poison
    // request can only be built as text — which is exactly how it arrives from
    // a non-Dart client, and how `1e999` got into the catalogue.
    final pair = channelPair();
    final api = FakeStateMan();
    final session = RelaySession.serve(
      resolver: const PermissiveSeriesResolver(),
      channel: pair.server,
      api: api,
      config: ServerConfig(),
      handles: HandleTable(),
      buffer: ConflatingSendBuffer(maxPending: 4096),
    );
    addTearDown(() async {
      await session.close(1000, 'test over');
      await api.dispose();
    });

    final answered = Completer<Map<String, Object?>>();
    pair.client.stream.listen((frame) {
      if (!answered.isCompleted) {
        answered.complete((jsonDecode(frame) as Map).cast<String, Object?>());
      }
    });
    pair.client.sink.add('{"jsonrpc":"2.0","id":"poison","method":"hello",'
        '"params":{"protocol":1e999,"supported":[],"client":{"name":"p",'
        '"version":"1"}}}');

    const budget = Duration(milliseconds: 500);
    final delivered = await within(
        answered.future.then((_) => true).timeout(budget, onTimeout: () => false),
        'the error answer to a request carrying 1e999',
        budget: const Duration(seconds: 2));

    expect(delivered, isTrue,
        reason: 'this is the 02-05 hang: an error response that echoes a '
            'request carrying Infinity cannot be encoded, the peer drops it, '
            'and a caller with no deadline waits forever');

    final error = ((await answered.future)['error'] as Map).cast<String, Object?>();
    expect(error['code'], ServerErrorCodes.typeMismatch);
    expect(((error['data'] as Map)['request'] as String), contains('omitted'),
        reason: 'the substitution is what keeps the answer sendable');
  });

  test('hello reports the tick this server actually runs at', () async {
    // A non-default tick, deliberately: a capability that happened to equal
    // the default would pass against a hard-coded constant, which is the exact
    // coupling this key exists to remove. The client's per-subscription
    // staleness arithmetic is derived from this number (04-RESEARCH Finding
    // 5), and a client constant that has to match a server config nobody diffs
    // is a mismatch that surfaces a year later as values the operator believes
    // are fresh.
    final link = _link(config: ServerConfig(tick: ServerConfig.minTick));
    addTearDown(link.dispose);

    final raw = await within(
        link.client.sendRequest(Methods.hello, _hello()), 'the hello result');
    final result = HelloResult.fromJson((raw as Map).cast());

    expect(result.capabilities['tickMs'], ServerConfig.minTick.inMilliseconds,
        reason: 'the handshake is the only place a client can learn the '
            'gateway\'s cadence; anything else is a constant on the client '
            'that nobody diffs against the server');
  });

  test('the advertised deadline is the config\'s own', () async {
    // **A non-default deadline, deliberately** — the same argument the tick
    // case above makes. A capability that happened to equal the default would
    // pass against a hard-coded literal, and a literal is exactly the failure
    // this key exists to prevent: the panel derives its heartbeat period from
    // this number, so a gateway configured for four seconds while advertising
    // six would have every panel beating at two seconds against a four-second
    // reaper — healthy panels thrown off with 4003, once a deadline, for ever
    // (07-08-SUMMARY deviation 3 is what that looks like from the other end).
    //
    // 4 s rather than 6: still under the 20 s `pingInterval` the constructor
    // insists on, and different from the default in a way arithmetic can see.
    const configured = Duration(seconds: 4);
    final link = _link(config: ServerConfig(heartbeatDeadline: configured));
    addTearDown(link.dispose);

    final raw = await within(
        link.client.sendRequest(Methods.hello, _hello()), 'the hello result');
    final result = HelloResult.fromJson((raw as Map).cast());

    expect(result.heartbeatDeadlineMs, configured.inMilliseconds,
        reason: 'the handshake is the only place a panel can learn how long '
            'this gateway lets it stay silent. Anything else is a constant on '
            'the client that nobody diffs against the server config, and the '
            'cost of the two disagreeing is every screen in the plant '
            'reconnecting and resyncing on a fixed cycle');
    expect(result.capabilities[HelloCapabilities.heartbeatDeadlineMs],
        configured.inMilliseconds,
        reason: 'it rides in the open capabilities map beside tickMs, under '
            'the key the protocol package names — a gateway that spelled it '
            'itself would be the second spelling, and the first typo in it is '
            'silent on both ends');
    expect(result.capabilities[HelloCapabilities.tickMs], isNotNull,
        reason: 'the new key is additive: the cadence a four-phase-old client '
            'already reads must still be there beside it');
  });

  test('an inbound ping keeps a session from being reaped', () async {
    // **The other half of the heartbeat, and the half that is easy to assume.**
    // The panel's pump is worth nothing if a `ping` is not evidence of life to
    // the gateway. `_lastSeen` is advanced by a `map` over the inbound frame
    // stream (`relay_session.dart`), so it is every application frame and not
    // a list of methods — but "so it is" is exactly the kind of sentence that
    // stops being true during a refactor that moves the touch into a handler
    // wrapper, and nothing else in the suite would notice.
    final link = _link();
    addTearDown(link.dispose);

    await within(
        link.client.sendRequest(Methods.hello, _hello()), 'the hello');

    // Long enough that the reading below cannot be the handshake's own touch
    // rounded to the same millisecond, and short enough to cost nothing.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final silentBeforePing = link.session.silentForMs();
    expect(silentBeforePing, greaterThan(0),
        reason: 'the clock has to have moved since the handshake, or the '
            'assertion below is comparing a number with itself and would pass '
            'against a session whose deadline nothing can move');

    await within(link.client.sendRequest(Methods.ping), 'a ping');

    expect(link.session.silentForMs(), lessThan(silentBeforePing),
        reason: 'a ping did not move this session\'s heartbeat deadline, so '
            'the client\'s pump is beating into a gateway that is not '
            'listening — every panel in the plant would still be reaped once '
            'a deadline and the pump would be pure cost');
  });

  test('the handler table is exactly the seventy-two names a client may call, '
      'plus the one it announces', () async {
    final link = _link();
    addTearDown(link.dispose);

    expect(
        link.session.registeredMethods,
        {
          Methods.hello,
          Methods.ping,
          Methods.subscribe,
          Methods.unsubscribe,
          Methods.write,
          Methods.writeStatus,
          // 14-12: the acknowledge. Constants here, a bare string in
          // `surface_test.dart` — that file pins the wire spelling, this one
          // pins the ledger.
          Methods.ackAlarm,
          Methods.read,
          Methods.readFresh,
          Methods.readMany,
          // 10-02: the first four data services. Constants here, bare strings
          // in `surface_test.dart` — that file pins the wire spelling, this
          // one pins the ledger.
          DataServiceMethods.browseFetchRoots,
          DataServiceMethods.browseFetchChildren,
          DataServiceMethods.browseFetchDetail,
          DataServiceMethods.browseResolvePath,
          // 10-03: the timeseries three (four until the 2026-09-07 audit cut
          // the count method). Constants here for the same reason the browse
          // four are — this file pins the ledger, not the wire spelling.
          DataServiceMethods.timeseriesQuery,
          DataServiceMethods.timeseriesQueryMultiple,
          DataServiceMethods.timeseriesQueryDownsampled,
          // 10-04: the history-view eleven, the largest family and the only
          // write-shaped one this phase that is not a preference.
          DataServiceMethods.historyCreateView,
          DataServiceMethods.historyUpdateView,
          DataServiceMethods.historyDeleteView,
          DataServiceMethods.historySelectViews,
          DataServiceMethods.historyGetKeys,
          DataServiceMethods.historyGetGraphs,
          DataServiceMethods.historyGetKeyNames,
          DataServiceMethods.historyAddPeriod,
          DataServiceMethods.historyDeletePeriod,
          DataServiceMethods.historyListPeriods,
          DataServiceMethods.historyRetentionHorizon,
          // 10-05: the preferences fifteen, which close the table. Seven of
          // them are the only names on this wire a `view` station may not
          // call — the ledger records that they are *registered*, and
          // `policy_test.dart` records who may reach them.
          DataServiceMethods.prefGetKeys,
          DataServiceMethods.prefGetAll,
          DataServiceMethods.prefGetBool,
          DataServiceMethods.prefGetInt,
          DataServiceMethods.prefGetDouble,
          DataServiceMethods.prefGetString,
          DataServiceMethods.prefGetStringList,
          DataServiceMethods.prefContainsKey,
          DataServiceMethods.prefSetBool,
          DataServiceMethods.prefSetInt,
          DataServiceMethods.prefSetDouble,
          DataServiceMethods.prefSetString,
          DataServiceMethods.prefSetStringList,
          DataServiceMethods.prefRemove,
          DataServiceMethods.prefClear,
          // 17-09: the access twenty-eight, iterated from the declared set
          // rather than restated — this file pins the ledger, and
          // `surface_test.dart` pins the wire spelling with bare strings.
          // Twenty-eight because the audit cut `accessTemplates.template`;
          // a name here that surface_test does not carry fails both files.
          ...AccessMethods.all,
          // 05-05: the hold tick, a client→server notification. It is in the
          // ledger because json_rpc_2 dispatches an un-idded frame through
          // the same table, and it is not a name a client may *call* — see
          // `surface_test.dart`, which keeps the two in separate literals.
          Methods.holdTick,
        },
        reason: 'the wire surface is a closed set of seventy-three '
            'registrations: 03-05 added subscribe and unsubscribe, 03-08 '
            'froze it, 04-02 added the five value methods the contract leg '
            'cannot run without, 10-02 the four browse ones that retired six '
            'of the thirteen proven-unreachable checks, 10-03 the four '
            'timeseries ones that retired three more, 10-04 the eleven '
            'history-view ones that retired two more, and 10-05 the '
            'preferences fifteen that retired the last two, 14-12 the '
            'acknowledge — the first operator action here that is not a '
            'write — and 17-09 the access twenty-eight, every one behind '
            'the same gate. A handler nobody counted is surface nobody '
            'reviewed');
  });
}
