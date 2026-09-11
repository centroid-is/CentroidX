/// A query too large to answer is a sentence, not a disconnect — over a real
/// socket, and through the fault proxy.
///
/// ## What this file is for
///
/// Every ceiling in this gateway before 10-10 was on ingress or on accumulated
/// bytes. A *response* goes into the session's priority lane, un-conflated,
/// drained only by the tick, and nothing bounded what one answer could be. An
/// undownsampled month-long window is about 21 MiB against a lane of 8, so the
/// verdict is `BufferDisconnect` → `close(4004)` and the operator is told they
/// disconnected. They did not; they asked for too much. 10-CONTEXT amendment 3
/// is that the gateway **refuses**, and that the refusal must never surface as
/// a disconnect.
///
/// The database-side boundary is 10-10 task 2's, in `tfc_relay_local`'s db
/// lane. This file is about what the **wire and the session** do with the
/// refusal once it is raised, and those are separable: the source here is a
/// `FakeTimeseries` that raises `ResultTooLarge` on demand, so these cases run
/// in this package's ordinary lane in a second rather than behind Docker.
///
/// ## Why it is not a contract check
///
/// `allContractChecks` is **78** — 51 until 17-05 merged the 27-check access
/// family, 50 until the 10-REVIEW fix cycle added the eighth data-services
/// check (CR-02, `preferences.clear`) — and both leg constants are 51 with
/// empty -32601 gap lists plus the named 27-check access gap (17-06/17-08 opt
/// the legs in; 17-14 empties it). This is a case *beside* them: the
/// contract is about properties every
/// `StateManApi` implementation must have, and "the gateway refuses an
/// over-large result rather than evicting you" is a property of this gateway's
/// wire, which `RemoteStateMan` has no way to satisfy on its own. Registering
/// it would move a number that three other files cross-check by text.
///
/// ## Reading the close assertions
///
/// `closeCode` on the client's own socket is null after a self-initiated close
/// on every platform (dart-lang/http#1698), so "the socket looks open" proves
/// nothing. What is asserted is the **gateway's own tracked code**:
/// `RelaySession.sentCloseCode`, and `RelayServer.closeLedger`, which is what
/// an operator's "did it leave, or did we evict it?" question is answered from.
@TestOn('vm')
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';

import 'support/client_harness.dart';

/// The ceiling the fake refuses against — 10-10's production default.
const int _rowLimit = 40000;

/// A key the plant serves, for the round trip that proves the session lived.
const String _liveKey = 'ST101.CN01.MOT01.speed';

/// The series the oversized queries ask for.
const String _series = 'ST101.CN01.MOT01.speed';

/// A source that refuses every raw window as over the row ceiling.
///
/// The shape 10-07's reader raises after 10-10: rows, `atLeast` because the
/// detection is `LIMIT n + 1` and therefore knows "over" and not "how far
/// over", and the downsampled method named as the way out.
///
/// [refusals] counts them, because "the second oversized query behaves the same
/// way" has to be a claim about two refusals rather than about one refusal and
/// one latched verdict.
final class _OversizeTimeseries extends FakeTimeseries {
  int refusals = 0;

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    refusals++;
    throw const ResultTooLarge.rows(
      limit: _rowLimit,
      measured: _rowLimit + 1,
      atLeast: true,
      suggestion: DataServiceMethods.timeseriesQueryDownsampled,
    );
  }
}

final DateTime _to = DateTime.utc(2026, 9, 3, 12);
final DateTime _monthBefore = _to.subtract(const Duration(days: 30));

/// One round trip that proves the session still answers — this suite's `ping`.
///
/// `RemoteStateMan` carries no `ping()` on its surface: the pipe's ping is the
/// heartbeat and it is sent on a timer, so a case that waited for one would be
/// measuring a timer rather than the session. `readFresh` is the smallest
/// request that crosses the socket and comes back with an answer from the plant
/// behind it, which is the same claim.
Future<DynamicValue> ping(RelayFixture fixture) =>
    fixture.api.readFresh(_liveKey);

/// The over-large ask, and the `RpcException` it must come back as.
Future<rpc.RpcException> askTooMuch(RelayFixture fixture) async {
  try {
    final answered = await fixture.api.timeseries
        .queryTimeseriesData(_series, _to, from: _monthBefore);
    fail('a month-long raw window answered with ${answered.length} samples '
        'instead of being refused. An answer here is the whole failure: it '
        'goes into the priority lane un-conflated and the session is evicted '
        'with ${CloseCodes.backpressureOverrun} a tick later');
  } on rpc.RpcException catch (error) {
    return error;
  }
}

/// The close codes the gateway recorded itself sending, live sessions and
/// finished ones together.
List<int?> sentCloses(RelayFixture fixture) => <int?>[
      for (final session in fixture.server.sessions.sessions)
        session.sentCloseCode,
      for (final close in fixture.server.closeLedger) close.serverCloseCode,
    ];

void main() {
  late RelayFixture fixture;
  late _OversizeTimeseries source;

  Future<void> stand({bool withProxy = false}) async {
    source = _OversizeTimeseries();
    fixture = relayFixture(timeseries: source, withProxy: withProxy);
    await fixture.ready;
    fixture.api.setValue(_liveKey, 1423.7);
    // The first round trip is also the barrier: it does not return until the
    // client has connected, said hello and been answered, so every later
    // assertion is about a session that was definitely up.
    await ping(fixture);
  }

  group('a refusal is not a disconnect', () {
    setUp(() => stand());

    test('the over-large query throws the refusal, naming the limit and the '
        'method that would answer it', () async {
      final error = await askTooMuch(fixture);

      expect(error.code, rpc_errors.INVALID_PARAMS,
          reason: 'not handlerFailed (-32011), which the wire documents as '
              'possibly transient. A panel that retried a month-long window '
              'forever is the denial of service the bound exists to prevent');
      expect(error.message, contains('$_rowLimit'),
          reason: 'the limit is in the SENTENCE, not only in a data map the '
              'client may or may not surface. An operator reads the message');
      expect(error.message, contains('at least'),
          reason: 'the detection is LIMIT n + 1, so the gateway knows the '
              'answer is over the cap and not by how much. A refusal quoting '
              '${_rowLimit + 1} as a count would tell an engineer to narrow '
              'the window by 0.0025% and hit the same wall');
      expect(error.message,
          contains(DataServiceMethods.timeseriesQueryDownsampled),
          reason: 'THIS is the deliverable. "Call '
              'timeseries.queryTimeseriesDataDownsampled" is a sentence an '
              'engineer acts on where a 4004 is not, and a message that '
              'degraded to "invalid params" over time would pass a code-only '
              'assertion forever');
    });

    test('the session answers the next request, and the one after that',
        () async {
      await askTooMuch(fixture);

      final value = await ping(fixture);
      expect(value.value, 1423.7,
          reason: 'the refusal cost the caller its answer and nothing else. '
              'A session that had to be re-established would show here as a '
              'readFresh that waited on the readiness barrier');

      fixture.api.setValue(_liveKey, 1500.0);
      final again = await ping(fixture);
      expect(again.value, 1500.0,
          reason: 'and the subscription behind it is still live, so a value '
              'set after the refusal still arrives — the anti-vacuity arm for '
              'the read above, which a cached answer would also have passed');
    });

    test('the gateway never set a close code', () async {
      await askTooMuch(fixture);
      await ping(fixture);

      expect(sentCloses(fixture), everyElement(isNull),
          reason: 'the gateway\'s OWN record, not the client\'s socket: '
              'closeCode is null after a self-initiated close on every '
              'platform (dart-lang/http#1698), so "the socket looks open" is '
              'not evidence. What must not have happened is '
              'applyVerdict(BufferDisconnect) → close(4004)');
      expect(sentCloses(fixture),
          isNot(contains(CloseCodes.backpressureOverrun)));
      expect(CloseCodes.backpressureOverrun, 4004,
          reason: 'spelled out once, because 4004 is the number an operator '
              'sees in a panel\'s log and the whole point of this file is '
              'that they do not see it for a query that was merely too big');
      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'the anti-vacuity arm: a session that had already gone '
              'would leave nothing to read a close code off, and the '
              'everyElement(isNull) arm above would pass over an empty list');
    });

    test('a second oversized query behaves exactly like the first', () async {
      final first = await askTooMuch(fixture);
      final second = await askTooMuch(fixture);

      expect(second.code, first.code);
      expect(second.message, first.message,
          reason: 'one-shot correctness would hide a latched verdict — a '
              'session that refused once and then answered, hung, or died on '
              'the second ask');
      expect(source.refusals, 2,
          reason: 'and both asks actually reached the source. A gateway that '
              'short-circuited the second from a cached error would pass the '
              'two arms above while never having asked');
      expect(sentCloses(fixture), everyElement(isNull));
      expect((await ping(fixture)).value, 1423.7);
    });
  });

  group('through the fault proxy, with the throttle engaged', () {
    setUp(() => stand(withProxy: true));

    test('the refusal still arrives as a refusal rather than as a stall',
        () async {
      // 64 kB/s: slow enough that a megabyte-scale answer would take seconds
      // and blow the client's 2 s control deadline, fast enough that a refusal
      // — a few hundred bytes — crosses in single-digit milliseconds. That gap
      // is the property being proven: a refusal is CHEAPER than the request
      // that caused it (`ws_malformed_test.dart:505-520`'s shape).
      fixture.proxy.throttleBytesPerSec = 64 * 1024;
      fixture.proxy.latency = const Duration(milliseconds: 3);

      final started = DateTime.now();
      final error = await askTooMuch(fixture);
      final took = DateTime.now().difference(started);

      expect(error.message,
          contains(DataServiceMethods.timeseriesQueryDownsampled));
      expect(took, lessThan(const Duration(seconds: 2)),
          reason: 'the deadline the client would have given up on. At '
              '64 kB/s the 21 MiB a month-long window would really be takes '
              'about six minutes, so a gateway that answered instead of '
              'refusing would fail here as a stall — which is how this same '
              'failure presents on a plant LAN under load');

      expect((await ping(fixture)).value, 1423.7,
          reason: 'and the session survived it on the fault path too, which '
              'is where an oversized response would first misbehave');
      expect(sentCloses(fixture), everyElement(isNull));
    });
  });
}
