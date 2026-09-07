/// `RemoteStateMan`: the `StateManApi` a panel actually holds.
///
/// The class is structurally `ChannelStateMan` — same store, same
/// synchronous-answers-from-cache shape, same `subscribe` adapter — and the
/// value of this file is entirely in the four differences a socket forces,
/// which `channel_state_man.dart:60-65` lists as deliberately absent there:
/// there is no connection at construction, every async method waits on a
/// readiness barrier, every request carries a deadline, and a write that dies
/// in flight resolves *unknown* rather than throwing.
///
/// **Why "constructs with nothing listening" is the first case.** The shared
/// contract suite calls `StateManApi Function() make` synchronously
/// (04-RESEARCH Finding 6), so a client that connected in its constructor could
/// not be handed to it at all. That constraint is also the right production
/// shape: a panel in the packing hall boots with the rest of the line, on a
/// switch still learning MAC addresses, and a client that threw at construction
/// would put the plant's start-up order in the operator's hands.
///
/// **The bite for CLI-06** is `an unchanged value notifies nobody`. A store
/// wired to notify unconditionally passes every other value case in this file —
/// the numbers are all correct, they just arrive too often — and fails that one.
/// It is asserted with an anti-vacuity arm in the same case: the counter must
/// move for the changed value that follows, or the zero is a measurement of
/// nothing.
///
/// **The bite for the write path** is `a reconnect re-queries status and never
/// re-actuates`. An implementation that re-sent the original `write` after a
/// reconnect passes "the write eventually resolves" and fails that one — and on
/// a plant, re-sending is a second stroke of a ram an operator commanded once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

/// A key `FakeStateMan` seeds at construction, so a subscribe against a real
/// gateway answers with a real snapshot and no plant has to be simulated.
const String _seededKey = 'PIPE.connected';

/// A second seeded key, so the write cases can move one value without
/// disturbing the one the notification cases are counting on.
const String _writableKey = 'PIPE.rtt_ms';

/// The budget for "the panel came back", named once and used everywhere.
///
/// Generous against the tick-quantised round trip this transport carries
/// (04-RESEARCH Finding 8) plus a capped backoff draw: a liveness budget, not a
/// latency measurement.
const Duration _recovery = Duration(seconds: 5);

/// The write deadline the expiry arm injects, small enough to fire inside the
/// case's own budget.
const Duration _writeDeadline = Duration(milliseconds: 200);

/// The platform band around a timer. A scheduler on a loaded CI box is not a
/// stopwatch, and a case that asserted an instant would fail one run in twenty
/// for a reason that has nothing to do with this client.
const Duration _band = Duration(seconds: 2);

/// The client's timing knobs, with the deadline floor lowered deliberately.
///
/// Lowering it is explicit and greppable for the reason `client_config.dart`
/// gives — nobody lowers it in production by accident. Here it buys deadlines
/// short enough that a gateway which accepts a socket and then says nothing
/// fails the pass inside a case's own budget instead of stalling it.
ClientConfig _config({Duration? write}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: write ?? const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// A real gateway on an ephemeral port, optionally behind a fault proxy.
///
/// The server package's own `relayFixture` is not reachable from here — it
/// lives in that package's `test/` tree, which no `package:` URI addresses — so
/// this is the same wiring, minus the client the fixture builds for itself.
Future<({FakeStateMan served, RelayServer server, FaultProxy? proxy, Uri uri})>
    _gateway({bool withProxy = false}) async {
  final served = FakeStateMan();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: ServerConfig(tick: ServerConfig.minTick),
    // Several arms here provoke errors on purpose; a suite that printed a stack
    // per provoked error trains everyone to scroll past them.
    onError: (_, __, ___) {},
  );
  await server.start();
  addTearDown(server.close);
  addTearDown(served.dispose);

  FaultProxy? proxy;
  if (withProxy) {
    proxy = FaultProxy(targetPort: server.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
  }
  final port = proxy?.port ?? server.port;
  return (
    served: served,
    server: server,
    proxy: proxy,
    uri: Uri.parse('ws://127.0.0.1:$port'),
  );
}

/// A client pointed at [uri], torn down with the case.
RemoteStateMan _client(Uri uri, {ClientConfig? config, Set<String>? keys}) {
  final client = RemoteStateMan(
    uri: uri,
    config: config ?? _config(),
    keys: keys ?? const {_seededKey, _writableKey},
  );
  addTearDown(client.dispose);
  return client;
}

/// A port nothing is bound to: the panel's ordinary state at power-on, and a
/// dial that will be refused for as long as the case cares to wait.
Future<Uri> _deadPort() async {
  final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = dead.port;
  await dead.close();
  return Uri.parse('ws://127.0.0.1:$port');
}

/// Polls [done] until it holds or [budget] runs out, and fails naming [what].
///
/// A poll rather than a stream wait because what these cases are asserting is a
/// *state* the client reached, and the transition that got it there is the
/// supervisor's business, tested in `reconnect_test.dart`.
Future<void> _until(String what, bool Function() done,
    {Duration budget = _recovery}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Long enough for the gateway's fan-out to have flushed whatever was set
/// before it, on a tick configured at [ServerConfig.minTick].
///
/// Used only where the property under test is that *nothing* arrives, which is
/// the one shape a poll cannot establish.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

/// Errors the fake gateway's script threw while answering, across the whole
/// file's run.
///
/// Collected rather than thrown, for the reason
/// `mode_integrity_test.dart:146-153` gives: the script runs inside a socket's
/// `listen` callback, in the ambient zone, long after the case that provoked
/// the request may have finished. Thrown from there it fails whichever case is
/// running — a red naming a file that is working, over a fault in one that is
/// not. Gathered here and read once at the end.
final List<String> _escaped = <String>[];

void main() {
  group('construction and the readiness barrier', () {
    test('constructing with nothing listening does not throw', () async {
      // A port nothing is bound to: the panel's ordinary state at power-on.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();

      final client = _client(Uri.parse('ws://127.0.0.1:$port'));

      // Constructed, dialling, and answering reads from an empty cache rather
      // than throwing or blocking.
      expect(client.read(_seededKey), isNull);
      expect(client.keys, isEmpty);
      expect(client.linkState, isNot(LinkState.ready));
    });

    test('a read before readiness answers from the cache synchronously',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);

      // Same event-loop turn as the constructor: nothing can have arrived, and
      // `read` is documented never to be a round trip.
      expect(client.read(_seededKey), isNull);

      await _until('the link to reach ready', () => client.isReady);
      expect(client.read(_seededKey), isNotNull);
    });

    test('a request issued before the link exists completes once it comes up',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);

      // Issued in the turn after construction — the barrier is shut, the peer
      // is null, and this call has to wait rather than fail.
      expect(client.isReady, isFalse);
      final value = await client.readFresh(_seededKey).timeout(_recovery);
      expect(value.quality, Quality.good);
    });

    test('dispose while a call is waiting for the link settles that call',
        () async {
      // The page that closed while a read was in flight. A future that never
      // settles is a spinner that never stops.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();

      final client = RemoteStateMan(
        uri: Uri.parse('ws://127.0.0.1:$port'),
        config: _config(),
        keys: const {_seededKey},
      );
      // The expectation is attached *before* the dispose that provokes the
      // failure. A future that rejects with nothing listening yet reports to
      // the isolate's ambient handler, which `package:test` attributes to
      // whichever case runs next — the same trap `readiness_barrier.dart:83-87`
      // mutes on its own side.
      final pending = client.readFresh(_seededKey);
      final settled =
          expectLater(pending.timeout(_recovery), throwsA(isA<StateError>()));
      await client.dispose();
      await settled;
    });
  });

  group('answers from the store', () {
    test('listen returns the same notifier instance for the same key',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);

      final first = client.listen(_seededKey);
      final second = client.listen(_seededKey);
      expect(identical(first, second), isTrue,
          reason: 'a widget holds the node it was handed');

      // And it survives the snapshot that fills it in — a resync that swapped
      // the node would take every listening widget dark.
      await _until('a snapshot', () => client.read(_seededKey) != null);
      expect(identical(client.listen(_seededKey), first), isTrue);
    });

    test('an unchanged value notifies nobody', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);

      await _until('the first value', () => client.read(_seededKey) != null);
      final node = client.listen(_seededKey);
      final held = node.value.value;

      var notifications = 0;
      void count() => notifications++;
      node.addListener(count);
      addTearDown(() => node.removeListener(count));

      // Exactly what is already on screen, pushed again — the ordinary shape of
      // a gateway re-reading a device that has not moved.
      gateway.served.setValue(_seededKey, held);
      await _settle();
      expect(notifications, 0,
          reason: 'CLI-06: a page with 1500 keys must cost k rebuilds per '
              'batch, not 1500');

      // Anti-vacuity: the counter has to be able to move, or the zero above is
      // a measurement of a listener that was never wired up.
      gateway.served.setValue(_seededKey, !(held as bool));
      await _until('the changed value',
          () => client.read(_seededKey)?.value == !held);
      expect(notifications, 1);
    });

    test('keys excludes a key that was asked for but never arrived', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('a snapshot', () => client.read(_seededKey) != null);

      // The mistyped page key. `listen` creates a node for anything, and
      // offering that back to the picker launders a typo into a valid binding.
      client.listen('PIPE.conected');

      expect(client.keys, contains(_seededKey));
      expect(client.keys, isNot(contains('PIPE.conected')));
    });

    test('a subscribe stream never listened to is still closed at dispose',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('a snapshot', () => client.read(_seededKey) != null);

      final handedOut = client.subscribe(_seededKey);
      await client.dispose();

      await expectLater(
          handedOut.isEmpty.timeout(const Duration(seconds: 2)),
          completion(isTrue));
    });

    test('a subscribe stream delivers the values that arrive on it', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('a snapshot', () => client.read(_seededKey) != null);

      final seen = <Object?>[];
      final sub = client.subscribe(_seededKey).listen((v) => seen.add(v.value));
      addTearDown(sub.cancel);

      gateway.served.setValue(_seededKey, false);
      await _until('the pushed value', () => seen.contains(false));
    });

    test('dispose is idempotent', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('a snapshot', () => client.read(_seededKey) != null);

      await client.dispose();
      await client.dispose();

      // And nothing is left ticking: the watchdog's deadline and the pending
      // reconnect are the only two timers this client ever owns.
      expect(client.debugTimerCount, 0);
    });
  });

  group('a write with no link under it', () {
    // The barrier has no clock of its own by design (`readiness_barrier.dart`:
    // "the supervisor owns the clock"), and the supervisor's clock only
    // schedules reconnects. So before 04-review CR-01 every deadline in
    // `ClientConfig` measured the round trip and nothing else: a write issued
    // against a gateway that was not there waited for a link forever, and then
    // went out the moment one appeared. That is a queue, and "no queue / no
    // retry" is the write-safety property.

    test('a write issued while the link is down settles unknown on its own '
        'deadline', () async {
      final client = _client(
        await _deadPort(),
        config: _config(write: _writeDeadline),
      );
      expect(client.isReady, isFalse);

      final started = DateTime.now();
      final result = await client
          .write(_writableKey, 7)
          .timeout(_writeDeadline * 10, onTimeout: () {
        fail('the write never settled: the operator\'s spinner never stops, '
            'and there is no outcome to act on');
      });
      final took = DateTime.now().difference(started);

      expect(result, isA<WriteUnknown>());
      expect((result as WriteUnknown).reason.kind, FailureKind.linkDown);
      expect(took, lessThan(_writeDeadline + _band),
          reason: 'a write must reach one terminal state inside its own '
              'deadline whatever the link is doing');
      expect(client.debugWritesSent, 0);
    });

    test('a write that expired waiting for a link is not dispatched when one '
        'arrives', () async {
      final gateway = await _gateway();
      var dialAllowed = false;
      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _config(write: _writeDeadline),
        keys: const {_seededKey, _writableKey},
        dial: (_) async {
          if (!dialAllowed) {
            throw const SocketException('the gateway is rebooting');
          }
          return connect(gateway.uri);
        },
      );
      addTearDown(client.dispose);

      final result = await client.write(_writableKey, 4242);
      expect(result, isA<WriteUnknown>());

      // The gateway comes back — ten minutes later on a plant, one backoff
      // window here.
      dialAllowed = true;
      await _until('the link to come up', () => client.isReady);
      await _settle();

      expect(client.debugWritesSent, 0,
          reason: 'a button pressed at 09:00 against a gateway that reboots '
              'for ten minutes must not actuate the machinery at 09:10');
      expect(gateway.served.mintedCmds, isEmpty,
          reason: 'nothing reached the plant for a write the operator was '
              'already told was unknown');
      expect(client.read(_writableKey)?.value, isNot(4242));
    });

    test('dispose while a write is parked resolves it unknown rather than '
        'throwing', () async {
      final client = _client(await _deadPort());

      // Attached before the dispose that provokes it, as the read case above
      // does: an unlistened rejection lands on the ambient handler and
      // `package:test` attributes it to whichever case runs next.
      final pending = client.write(_writableKey, 1);
      final settled = expectLater(
        pending.timeout(_recovery),
        completion(isA<WriteUnknown>()),
        reason: 'a closing page gets a WriteResult, not a StateError: '
            '`write` never throws to report an outcome',
      );
      await client.dispose();
      await settled;
    });

    test('a write after dispose is an outcome, not a throw', () async {
      final client = _client(await _deadPort());
      await client.dispose();

      final result = await client.write(_writableKey, 1).timeout(_recovery);
      expect(result, isA<WriteUnknown>());
      expect(client.debugWritesSent, 0);
    });
  });

  // 04-REVIEW WR-07. `ClientPreferencesApi.announce` documented itself as
  // "called from the notification handler and nowhere else", and there was no
  // such handler: the supervisor registered update/tick/resync/status/bye and
  // a fallback that *refused* anything else, so the gateway's own
  // announcement came back `-32000 this panel does not answer
  // "preferences.changed"` and the change stream could never emit.
  group('preferences announced by the gateway', () {
    test('a preferences.changed notification reaches a local listener',
        () async {
      final gateway = await _FakeGateway.start((link, method, id, params) {
        switch (method) {
          case Methods.hello:
            link.hello(id);
          case Methods.subscribe:
            link.snapshot(id, defaultPageSubscription);
          default:
            break;
        }
      });
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final changed = <String>[];
      final listening =
          client.preferences.onPreferencesChanged.listen(changed.add);
      addTearDown(listening.cancel);

      // Phase 10 migrated the frame to a key list wholesale — see
      // `preferences_changed_test.dart` for the fan-out this case now rides.
      gateway.notifyLive(DataServiceMethods.preferencesChanged, {
        'keys': ['ui.theme'],
      });

      await _until('the announcement to reach the stream',
          () => changed.isNotEmpty);
      expect(changed, ['ui.theme'],
          reason: 'a settings page edited on one panel has to reach the chart '
              'legend on the next one, and the whole path for that is this '
              'notification');
      expect(client.complaints, isEmpty);
    });
  });

  group('the write path', () {
    test('a write mints a cmd and reports what became of it', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);

      final result = await client.write(_writableKey, 42);

      expect(result, isA<WriteApplied>());
      // The hand-rolled ULID from 01-04 — 26 Crockford characters. A second
      // generator in this package would be a second id space the gateway has
      // to reconcile `writeStatus` against.
      expect(result.cmd, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
      expect(client.debugWritesSent, 1);
    });

    test('a non-finite value is refused before anything reaches the wire',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      for (final offender in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await expectLater(
          () => client.write(_writableKey, offender),
          throwsA(isA<ArgumentError>()),
          reason: 'a widget that divides by zero must not actuate a PLC tag',
        );
      }

      // Sanitizing a value is right for telemetry, where the alternative is a
      // frame that fails for every client on the pipe. It is wrong here: this
      // is the client's own request channel, nothing has been sent yet, and
      // nulling the value would put a write of `null` on a plant tag — the
      // device actuated with something nobody chose — and then report
      // `WriteApplied` for it. `WriteParams`' own factory already refuses
      // exactly this; refusing here costs nothing and owes the caller the
      // reason.
      expect(client.debugWritesSent, 0,
          reason: 'nothing may reach the wire for a value the operator '
              'cannot have chosen');
    });

    test('a non-finite expect is refused before anything reaches the wire',
        () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      await expectLater(
        () => client.write(_writableKey, 1, expect: double.infinity),
        throwsA(isA<ArgumentError>()),
      );
      expect(client.debugWritesSent, 0,
          reason: 'null is this path\'s encoding of "no guard at all", so '
              'sanitizing one turns the operator\'s "only if it still reads '
              '1200" into "whatever it reads"');
    });

    test('a second write under a live cmd is refused before it reaches the '
        'wire', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      // The first write is left unresolved by stalling the plant, which is
      // what "already in flight" means.
      gateway.served.stallWrites();
      final cmd = newUlid();
      final first = client.write(_writableKey, 1, cmd: cmd);
      await _until('the write to reach the plant',
          () => gateway.served.writesInFlight > 0);

      await expectLater(
        () => client.write(_writableKey, 2, cmd: cmd),
        throwsA(isA<ArgumentError>()),
        reason: 'the unresolved set is keyed by cmd, so two live writes '
            'sharing one id are one entry: whichever settles first removes '
            'it, and the other unknown is never re-queried',
      );
      expect(client.debugWritesSent, 1,
          reason: 'nothing reached the wire for the second write, which is '
              'what makes the refusal safe to raise');

      gateway.served.releaseWrites();
      await first.timeout(_recovery);
    });

    test('a socket killed mid-write resolves unknown and does not throw',
        () async {
      final gateway = await _gateway(withProxy: true);
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      final pending = client.write(_writableKey, 7);
      gateway.proxy!.killOnce();

      final result = await pending.timeout(_recovery);
      expect(result, isA<WriteUnknown>(),
          reason: 'nobody knows whether the machine moved, and reporting a '
              'lost link as a refusal tells an operator a valve definitely did '
              'not open when it may well have');
      expect(
          (result as WriteUnknown).reason.kind,
          anyOf(FailureKind.linkLost, FailureKind.linkDown,
              FailureKind.deadlineExpired));
    });

    test('a write whose deadline expires resolves unknown', () async {
      // A gateway that answers the handshake and the page and then simply never
      // answers the write. `json_rpc_2` has no per-request timeout of its own
      // (04-RESEARCH Finding 1), so without the deadline seam this future never
      // settles: the socket is fine, nothing is stale, and the operator has a
      // spinner and no symptom to report beyond "it is just sitting there".
      final silent = await _FakeGateway.start((link, method, id, params) {
        switch (method) {
          case Methods.hello:
            link.hello(id);
          case Methods.subscribe:
            link.snapshot(id, defaultPageSubscription);
          default:
            break; // `write` included, deliberately
        }
      });
      final client = _client(
        Uri.parse('ws://127.0.0.1:${silent.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final started = DateTime.now();
      final result = await client.write(_seededKey, 1).timeout(_recovery);
      final took = DateTime.now().difference(started);

      expect(result, isA<WriteUnknown>());
      expect((result as WriteUnknown).reason.kind, FailureKind.deadlineExpired);
      // A claim about the window the answer landed in, which is the only honest
      // claim about a timer on a machine that also runs a CI job.
      expect(took, lessThan(_writeDeadline + _band));
    });

    test('a server refusal resolves rejected, carrying the reason', () async {
      final gateway = await _gateway();
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      // A shape refusal, raised before the plant is touched — the one class of
      // write failure that is definitively "no effect".
      final result = await client.write('   ', 1);

      expect(result, isA<WriteRejected>());
      final rejected = result as WriteRejected;
      expect(rejected.reason.kind, FailureKind.serverRefused);
      expect(rejected.reason.status, startsWith('jsonrpc:'));
      expect(rejected.reason.message, isNotEmpty);
    });

    test('a reconnect re-queries status and never re-actuates', () async {
      final gateway = await _gateway(withProxy: true);
      final client = _client(gateway.uri);
      await _until('the link', () => client.isReady);

      // One write that resolves cleanly before the drop, so the re-query has
      // something it must *not* ask about.
      final settled = await client.write(_writableKey, 1);
      expect(settled, isA<WriteApplied>());

      final pending = client.write(_writableKey, 9);
      gateway.proxy!.killOnce();
      final lost = await pending.timeout(_recovery);
      expect(lost, isA<WriteUnknown>());

      // Anti-vacuity: there has to be something in flight, or the assertion
      // below is a claim about an empty set.
      expect(client.debugUnresolvedCmds, contains(lost.cmd));
      expect(client.debugUnresolvedCmds, isNot(contains(settled.cmd)));

      await _until('the status re-query after the reconnect',
          () => client.debugWriteStatusQueries.isNotEmpty);

      expect(client.debugWriteStatusQueries.first, equals([lost.cmd]),
          reason: 'a command that resolved before the drop has a known answer, '
              'and re-querying it is a question nobody needed asked');
      expect(client.debugWriteStatusQueries, hasLength(1));
      expect(client.debugWritesSent, 2,
          reason: 'the write is never re-sent: on a plant that is a second '
              'stroke of a ram the operator commanded once');
    });
  });

  // The other end of the re-query. Everything above asserts that the question
  // goes out; these assert that the answer is used — 04-REVIEW WR-02 and WR-03,
  // and the observable CR-02 was found through.
  group('what the re-query comes back with', () {
    /// A gateway that answers the handshake and the page, never answers a
    /// write, and answers `writeStatus` with whatever [answer] makes of the
    /// cmds it was asked about.
    Future<_FakeGateway> statusGateway(
            List<Object?> Function(List<String> cmds) answer) =>
        _FakeGateway.start((link, method, id, params) {
          switch (method) {
            case Methods.hello:
              link.hello(id);
            case Methods.subscribe:
              link.snapshot(id, defaultPageSubscription);
            case Methods.writeStatus:
              final cmds = <String>[
                for (final raw in (params['cmds'] as List? ?? const []))
                  '$raw',
              ];
              link.result(id, {'results': answer(cmds)});
            default:
              break; // `write` included, deliberately
          }
        });

    Map<String, Object?> applied(String cmd, Object? readback) =>
        WriteApplied(cmd,
                readback: readback,
                at: DateTime.now().millisecondsSinceEpoch)
            .toJson();

    test('an applied answer resolves the command and lands in the store',
        () async {
      final gateway =
          await statusGateway((cmds) => [for (final cmd in cmds) applied(cmd, 4242)]);
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final resolutions = <WriteResult>[];
      final listening = client.onWriteResolved.listen(resolutions.add);
      addTearDown(listening.cancel);

      final unknown = await client.write(_seededKey, 4242).timeout(_recovery);
      expect(unknown, isA<WriteUnknown>());
      expect(client.debugUnresolvedCmds, contains(unknown.cmd));

      await gateway.dropLive();
      await _until('the re-query to be answered',
          () => client.debugWriteStatusAnswers.isNotEmpty);
      await pumpEventQueue();

      expect(resolutions.single, isA<WriteApplied>(),
          reason: 'an operator who was told "unknown", walked out to look at '
              'the machine and came back learns nothing when the gateway '
              'finally answers "applied"');
      expect(resolutions.single.cmd, unknown.cmd);
      expect(client.debugUnresolvedCmds, isEmpty);
      expect(client.read(_seededKey)?.value, 4242,
          reason: 'the readback is what the device reported holding, and the '
              'direct path adopts it. A confirmation that arrives late is '
              'still the confirmation');
    });

    test('an unknown answer is asked about again on the next reconnect',
        () async {
      // 04-REVIEW WR-01's operator-visible property. The storm guard is
      // cleared in the `finally` of the call it belongs to, and it used to be
      // cleared there and nowhere else: a re-query wanted while one was in
      // flight was dropped rather than run afterwards, and on a link that then
      // behaved, "some later entry to ready" never came.
      //
      // What this case forces is the outer property — while a command is
      // unresolved, every reconnect asks about it again. The precise
      // interleaving WR-01 names (a reconnect completing before the previous
      // call's future has failed) cannot be forced from outside the client:
      // closing a peer fails its in-flight requests in the same breath, and
      // that failure unwinds in microtasks while a reconnect costs a backoff
      // window plus a handshake.
      final gateway = await statusGateway((cmds) => [
            for (final cmd in cmds)
              WriteUnknown(
                      cmd,
                      const WriteReason('in_flight',
                          message: 'still upstream'))
                  .toJson(),
          ]);
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final unknown = await client.write(_seededKey, 1).timeout(_recovery);
      expect(client.debugUnresolvedCmds, contains(unknown.cmd));

      await gateway.dropLive();
      await _until('the first re-query',
          () => client.debugWriteStatusQueries.length == 1);
      await gateway.dropLive();
      await _until('the re-query after the second reconnect',
          () => client.debugWriteStatusQueries.length >= 2);

      expect(client.debugUnresolvedCmds, contains(unknown.cmd),
          reason: 'an unknown answer settles nothing, which is exactly what '
              'makes it re-queryable');
      expect(client.debugWritesSent, 1,
          reason: 'asking twice is recovery; sending twice is a second '
              'actuation');
    });

    test('one undecodable entry costs one command, not the batch', () async {
      final gateway = await statusGateway((cmds) => [
            // The malformed entry comes *first*, which is the shape that used
            // to discard every settled outcome behind it.
            'this is not a write result',
            applied(cmds.last, 7),
          ]);
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey, _writableKey},
      );
      await _until('the link', () => client.isReady);

      final first = await client.write(_seededKey, 1).timeout(_recovery);
      final second = await client.write(_writableKey, 7).timeout(_recovery);
      expect(client.debugUnresolvedCmds, hasLength(2));

      await gateway.dropLive();
      await _until('the re-query to be answered',
          () => client.debugWriteStatusAnswers.isNotEmpty);

      expect(client.debugUnresolvedCmds, isNot(contains(second.cmd)),
          reason: 'the second command had a perfectly good answer in the same '
              'batch, and a malformed entry at index 0 threw it away with the '
              'rest. On a 1500-key panel that batch is not small');
      expect(client.debugUnresolvedCmds, contains(first.cmd),
          reason: 'nothing legible came back about the first command, so it '
              'stays held for the next entry to ready');
      expect(client.complaints, isNotEmpty,
          reason: 'a dropped entry that nobody records is a page that goes '
              'half-blank with nothing in the log');
    });

    test('writeStatus answers in the order it was asked', () async {
      // The public member, asked directly rather than through the reconnect
      // recovery that shares its one request-building seam. Element *i*
      // answers `cmds[i]`: a caller reconciling a reconnect must not have to
      // trust a map key round trip to know which command it is being told
      // about.
      final gateway = await statusGateway(
          (cmds) => [for (final cmd in cmds) applied(cmd, cmds.indexOf(cmd))]);
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final answers = await client
          .writeStatus(const ['01ONE', '01TWO', '01THREE']).timeout(_recovery);

      expect(answers.map((a) => a.cmd).toList(), ['01ONE', '01TWO', '01THREE']);
      expect(answers.every((a) => a is WriteApplied), isTrue);
    });

    test('an entry about another command is not an answer about this one',
        () async {
      // 05-REVIEW WR-01. Positional alignment is the interface's promise
      // (`state_man_api.dart`: "element i answers cmds[i]"), and the caller
      // has no other way to know which command it is being told about. The
      // absent and the undecodable cases were hardened in 04-REVIEW deviation
      // 4; this is the shifted one — a version-skewed build, a batching bug, a
      // peer that is not the gateway. The hazard is precise: `not_received` is
      // the one verdict in the system that licenses a second movement of a
      // machine, and read against the wrong command it invites a re-send of
      // one that may well have actuated.
      final gateway = await statusGateway((cmds) => [
            // Both entries are perfectly well-formed. They are about the
            // wrong commands, which no amount of decoding can detect.
            const WriteNotReceived('01TWO').toJson(),
            applied('01ONE', 7),
          ]);
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        config: _config(write: _writeDeadline),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);

      final answers =
          await client.writeStatus(const ['01ONE', '01TWO']).timeout(_recovery);

      expect(answers, hasLength(2),
          reason: 'a mismatched entry was dropped rather than substituted, '
              'which shifts every later answer onto the wrong command — the '
              'failure the absent case was hardened against');
      expect(answers[0].cmd, '01ONE',
          reason: 'the answer at position 0 is about ${answers[0].cmd}, so the '
              'caller pairing it with cmds[0] is reading a verdict about some '
              'other command');
      expect(answers[0].isSafeToResend, isFalse,
          reason: 'the gateway put a not_received about 01TWO at 01ONE\'s '
              'position and the client passed it on as an answer about 01ONE. '
              'That is a re-send offered for a command that may already have '
              'moved the machine');
      expect(answers[0], isA<WriteUnknown>(),
          reason: 'an entry about a different command rules nothing out about '
              'this one, and unknown is what "nothing can be ruled out" is '
              'spelled as');
      expect(answers[1].cmd, '01TWO');
      expect(answers[1], isA<WriteUnknown>(),
          reason: 'the applied entry at position 1 is about 01ONE; taken as an '
              'answer about 01TWO it would tell an operator a write landed '
              'that nobody has heard about');
      expect(client.complaints, isNotEmpty,
          reason: 'a gateway answering out of order is a real fault and the '
              'only trace of it would be two commands quietly going unknown');
    });
  });

  group('the hold-to-run path', () {
    /// A gateway that answers the handshake, the page, and every write as
    /// applied — so an engage takes and the handle that comes back is live.
    Future<_FakeGateway> holdGateway() =>
        _FakeGateway.start((link, method, id, params) {
          switch (method) {
            case Methods.hello:
              link.hello(id);
            case Methods.subscribe:
              link.snapshot(id, defaultPageSubscription);
            case Methods.write:
              link.result(
                  id,
                  WriteApplied('${params['cmd']}',
                          readback: params['value'],
                          at: DateTime.now().millisecondsSinceEpoch)
                      .toJson());
            default:
              break;
          }
        });

    List<Map<String, Object?>> framesOf(_FakeGateway gateway, String method) =>
        [
          for (final frame in gateway.frames)
            if (frame['method'] == method)
              ((frame['params'] as Map?) ?? const {}).cast<String, Object?>(),
        ];

    Future<(_FakeGateway, RemoteStateMan)> engaged() async {
      final gateway = await holdGateway();
      final client = _client(
        Uri.parse('ws://127.0.0.1:${gateway.port}'),
        keys: const {_seededKey},
      );
      await _until('the link', () => client.isReady);
      return (gateway, client);
    }

    test('an engage is an ordinary write frame carrying the hold flag',
        () async {
      // D-P5-C. The engage stays a write — that is what buys it a three-state
      // outcome, an entry in the gateway's outcome log, and `writeStatus`
      // reconciliation across a reconnect with no new code. The flag is the
      // one bit that tells the gateway to take a handle for it.
      final (gateway, client) = await engaged();

      final hold = await client.holdToRun(_seededKey).timeout(_recovery);

      expect(hold.isHeld, isTrue);
      expect(hold.engagement, isA<WriteApplied>());
      final engage = framesOf(gateway, Methods.write).single;
      expect(engage['hold'], true);
      expect(engage['value'], 1);
      expect(engage['key'], _seededKey);
      expect(engage['cmd'], isA<String>(),
          reason: 'an engage is a real operator action, so it carries the id '
              'writeStatus reconciles it under');
      expect(client.debugWritesSent, 1);
    });

    test('a tick is one notification carrying the key and the counter and no '
        'cmd', () async {
      final (gateway, client) = await engaged();
      final hold = await client.holdToRun(_seededKey).timeout(_recovery);

      hold.tick();
      hold.tick();

      await _until('both ticks to reach the gateway',
          () => framesOf(gateway, Methods.holdTick).length == 2);
      await _settle();
      expect(framesOf(gateway, Methods.holdTick), [
        {'k': _seededKey, 'n': 2},
        {'k': _seededKey, 'n': 3},
      ], reason: 'the engage already wrote 1, and a tick carries no cmd: it '
          'has no outcome to correlate, and giving it one would invite '
          'somebody to await it');
      expect(client.debugHoldTicksSent, 2);
    });

    test('a tick on a dead link is not sent and is not swallowed', () async {
      // Two arms, and the second is the one that bites.
      //
      // The behavioural arm can only say that nothing was sent and nothing
      // threw — which a `try`/`catch` around the send would also satisfy,
      // because leaving `ready` has already released the handle by then.
      // The structural arm is what tells the two apart, and the difference
      // matters: `classifyFailure` (`failure_taxonomy.dart:143-148`) rethrows
      // unrecognised `StateError`s on purpose, so a catch here would swallow
      // a real defect in this process along with the one it meant to ignore.
      final (gateway, client) = await engaged();
      final hold = await client.holdToRun(_seededKey).timeout(_recovery);
      hold.tick();
      await _until('the first tick', () => client.debugHoldTicksSent == 1);

      // Shut down rather than drop: a reconnect racing the assertion would
      // make the case a coin toss about backoff timing.
      await gateway.shutdown();
      await _until('the client to notice the link is gone',
          () => !client.isReady);
      final sent = client.debugHoldTicksSent;

      expect(hold.tick, returnsNormally);
      await _settle();
      expect(client.debugHoldTicksSent, sent,
          reason: 'nothing may be handed to a socket nobody is reading: the '
              'dart:io sink buffers without bound and has no flush(), so a '
              'pump that kept ticking would build exactly the queue this '
              'project forbids');

      final pump = _sourceOf('void _sendHoldTick(');
      expect(pump.where((line) => line.contains('try')), isEmpty,
          reason: 'the pump gates, it does not catch. Lines checked:\n'
              '${pump.join('\n')}');
      expect(pump.any((line) => line.contains('LinkState.ready')), isTrue,
          reason: 'the gate on link readiness is the whole mechanism; '
              'sendNotification on a closed peer throws StateError '
              'synchronously (measured, 05-RESEARCH §B.1 #5)');
    });

    test('losing the link releases the hold with reason disconnect', () async {
      // A dead link *is* a release trigger. Waiting for a write deadline
      // would leave the counter advancing into a socket nobody is reading for
      // up to two budgets.
      final (gateway, client) = await engaged();
      final hold = await client.holdToRun(_seededKey).timeout(_recovery);
      expect(hold.isHeld, isTrue);

      await gateway.shutdown();

      expect(await hold.onReleased.timeout(_recovery), HoldEnded.disconnect);
      expect(hold.isHeld, isFalse);
    });

    test('disposing the client releases every live hold', () async {
      final (gateway, client) = await engaged();
      final hold = await client.holdToRun(_seededKey).timeout(_recovery);

      await client.dispose();

      expect(await hold.onReleased.timeout(_recovery), HoldEnded.disposed,
          reason: 'a panel that closed while a button was held must not leave '
              'a counter advancing behind it');
      expect(hold.isHeld, isFalse);
      expect(framesOf(gateway, Methods.holdTick), isEmpty);
    });
  });

  group('the fake gateway itself', () {
    test('a link that closed its own socket is never written to again',
        () async {
      // The parked "Bad state: StreamSink is closed" flake, reduced to a
      // sequence (05 deferred-items; 07-RESEARCH §E.1). `dart:io` closes the
      // outgoing sink *synchronously* inside `close()` and only moves
      // `readyState` when the close handshake completes, so a **self**-initiated
      // close leaves a window — measured at ~3 ms with a peer listening — in
      // which `readyState` reads `open` and `add` throws. `dropLive()` self-
      // closes while a scripted answer to an in-flight request is still queued,
      // which is why the flake was one standalone run in six: a 3 ms window.
      //
      // Deterministic here because the send happens in the same turn as the
      // close, which is inside the window every time rather than one time in
      // six. Nothing about the client is under test; this is the scaffolding
      // proving it cannot throw into whichever case happens to be running.
      final gateway = await _FakeGateway.start((link, method, id, params) {
        link.result(id, null);
      });
      final peer = await WebSocket.connect('ws://127.0.0.1:${gateway.port}');
      peer.listen((Object? _) {}, onError: (Object _) {}, cancelOnError: true);
      addTearDown(() => peer.close().catchError((Object _) => null));
      await _until('the gateway to accept the peer', () => gateway.accepted == 1);
      final link = gateway._links.last;

      // No `await` between these three statements on purpose: the window opens
      // the instant `close()` is called and the point is to be inside it.
      final dropping = gateway.dropLive();
      expect(link.socket.readyState, WebSocket.open,
          reason: 'the socket already reads closed here, so the send below is '
              'not inside the window this case exists to cover and a guard on '
              'readyState alone would be enough after all');
      expect(
          () => link._send(const {
                'jsonrpc': '2.0',
                'method': 'tick',
                'params': <String, Object?>{},
              }),
          returnsNormally,
          reason: 'the fake gateway threw while answering a request on a '
              'socket it had just closed itself. A scaffold throw is never the '
              'finding: it escapes into the ambient zone and is attributed to '
              'whichever case is running, so the report names a file that is '
              'working over a fault in one that is not');
      await dropping;
    });

    test('and it is the close flag holding, not the catch', () async {
      // Anti-vacuity for the case above. Without this arm, `returnsNormally`
      // is satisfied by a `_send` that never reaches the socket at all — or by
      // a window that closed on its own between two Dart releases — and the
      // guard would look like it was holding long after it stopped being what
      // held.
      //
      // The same sequence with the flag forced back off: `readyState` still
      // says `open`, the sink is still gone, and the throw the flag was
      // preventing lands in `swallowed` instead of the zone.
      final gateway = await _FakeGateway.start((link, method, id, params) {
        link.result(id, null);
      });
      final peer = await WebSocket.connect('ws://127.0.0.1:${gateway.port}');
      peer.listen((Object? _) {}, onError: (Object _) {}, cancelOnError: true);
      addTearDown(() => peer.close().catchError((Object _) => null));
      await _until('the gateway to accept the peer', () => gateway.accepted == 1);
      final link = gateway._links.last;

      final dropping = gateway.dropLive();
      expect(link.socket.readyState, WebSocket.open,
          reason: 'the socket reads closed already, so the readyState guard '
              'would have caught this on its own and the arm is measuring '
              'nothing');

      // Flag on: the frame never reaches the sink at all.
      link._send(const {'jsonrpc': '2.0', 'method': 'tick'});
      expect(link.swallowed, isEmpty,
          reason: 'the frame reached the sink and the catch is what stopped '
              'the throw, not the close flag. The catch is belt and braces; a '
              'scaffold relying on it is one guard away from the flake being '
              'back and invisible');

      // Flag off, same sequence, same turn: the throw the flag was preventing.
      link._closing = false;
      link._send(const {'jsonrpc': '2.0', 'method': 'tick'});

      expect(link.swallowed, hasLength(1),
          reason: 'with the close flag off the sink accepted a frame after '
              'this side had closed it, which means the window the flag exists '
              'for is gone and the guard above is now passing for a reason '
              'nobody chose. If dart:io has genuinely fixed this, delete the '
              'flag deliberately rather than leaving a guard whose failure is '
              'invisible');
      expect(link.swallowed.single, isStateError);
      link._closing = true;
      await dropping;
    });

    test('no scripted answer escaped into the zone', () async {
      // Read once, at the end, and only meaningful in a full-file run: an
      // error thrown from the script lands whenever the frame that provoked it
      // arrives, which can be after the case that sent it has passed.
      await _settle();
      expect(_escaped, isEmpty,
          reason: 'the fake gateway threw while answering a request and the '
              'throw escaped into the ambient zone: $_escaped. That is the '
              'parked "StreamSink is closed" flake\'s shape — a scaffold fault '
              'failing whichever case happened to be running, one run in six');
    });
  });
}

/// The source lines of the member whose declaration begins [member], in
/// `lib/src/remote_state_man.dart`.
///
/// [member] is the start of the *declaration* — `'void _sendHoldTick('` and
/// not `'_sendHoldTick'` — because a bare name matches the call site that
/// installs it as a callback first, and the range walked from there is
/// somebody else's method.
///
/// Reading the implementation as text is `client_config_test.dart:202-222`'s
/// shape and `no_retry_test.dart`'s, and it is here for the same reason it is
/// there: the property is about a seam that does not exist yet — a `try` some
/// future refactor wraps around a send — and no behavioural case can see the
/// absence of something nobody has written.
List<String> _sourceOf(String member) {
  final file = File('lib/src/remote_state_man.dart');
  expect(file.existsSync(), isTrue,
      reason: 'the file this sweep reads has moved; ${file.path} is relative '
          'to the package root, which is where dart test runs');
  final lines = file.readAsLinesSync();
  final start = lines.indexWhere((line) => line.trimLeft().startsWith(member));
  expect(start, isNot(-1), reason: '$member is not in ${file.path}');
  final end = lines.indexWhere((line) => line == '  }', start);
  expect(end, isNot(-1), reason: '$member has no closing brace at top level');
  return lines.sublist(start, end + 1);
}

// ---------------------------------------------------------------------------
// A hand-rolled gateway, for the one thing the real server cannot be asked to
// do: answer `hello` and `subscribe`, and then never answer a `write`.
// ---------------------------------------------------------------------------

/// How a scripted gateway answers one request.
typedef _Script = void Function(
    _FakeLink link, String method, int id, Map<String, Object?> params);

/// A gateway that answers JSON-RPC by script. It speaks only what the deadline
/// arm needs, which is two methods and a silence.
final class _FakeGateway {
  _FakeGateway._(this._http, this._script);

  static Future<_FakeGateway> start(_Script script) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _FakeGateway._(http, script);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final _Script _script;
  final List<_FakeLink> _links = <_FakeLink>[];

  /// Every frame this gateway has been sent, in order, decoded.
  ///
  /// Recorded rather than scripted because the hold cases assert on frames
  /// the script never sees: a tick carries no id, so [_script] is never
  /// called for one, and "exactly one notification per tick, with no cmd on
  /// it" is a claim about what left the client rather than about what was
  /// answered.
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];

  int get port => _http.port;

  /// How many sockets this gateway has accepted. One per client dial, so a
  /// case can wait for the reconnect rather than for a duration.
  int get accepted => _links.length;

  /// Sends a notification to the live client, the way the gateway announces
  /// one. No id: nothing that needs an outcome is ever a notification.
  void notifyLive(String method, Map<String, Object?> params) {
    if (_links.isEmpty) return;
    _links.last._send({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  /// Hangs up on the live client, without a close code, the way a plant switch
  /// does. The client's answer to that is always to come back.
  Future<void> dropLive() async {
    if (_links.isEmpty) return;
    final link = _links.last;
    // Marked **before** the close, not after: the window [_FakeLink._closing]
    // documents opens the instant `close()` is called, and a flag set after the
    // await is a flag set on the far side of it.
    link._closing = true;
    await link.socket.close().catchError((Object _) => null);
  }

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      final link = _FakeLink(socket);
      _links.add(link);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          frames.add(frame.cast<String, Object?>());
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          final params = frame['params'];
          // The script answers on a socket this gateway may be closing under
          // it. A throw here has nowhere to go: `listen`'s callback runs in the
          // ambient zone, so it fails whichever *case* is running rather than
          // this one, which is how a scaffold defect gets read as a product
          // defect in another file. Collected and read once at the end of the
          // run instead — `mode_integrity_test.dart:296-304`'s shape.
          try {
            _script(link, method, id,
                params is Map ? params.cast<String, Object?>() : const {});
          } catch (error, stack) {
            _escaped.add('the fake gateway\'s script answering $method: '
                '${error.runtimeType} — $error\n$stack');
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  Future<void> shutdown() async {
    // Every link is marked before any of them is closed. Closing one link can
    // let the client's next frame through to another, and a gateway that
    // marked them one at a time would have the same window on link two that
    // [_FakeLink._closing] exists to close on link one.
    for (final link in _links) {
      link._closing = true;
    }
    for (final link in _links) {
      await link.socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

/// One accepted socket on a [_FakeGateway].
final class _FakeLink {
  _FakeLink(this.socket);

  final WebSocket socket;

  /// Whether *this* side is the one that asked for the close.
  ///
  /// **`dart:io` will not tell you this, so track it.** `close()` closes the
  /// outgoing sink synchronously and `readyState` only moves when the close
  /// handshake completes, which leaves a window — measured at ~3 ms with a peer
  /// listening, indefinitely without one (07-RESEARCH §E.1) — where
  /// `readyState` reads `open` and `add` throws `Bad state: StreamSink is
  /// closed`. This is the same defect class CLAUDE.md already lists for the
  /// client adapter: *"`closeCode` null after self-initiated close
  /// (dart-lang/http#1698) → track own close codes"*, and the same guard
  /// `frame_seam.dart:109` makes with `if (!incoming.isClosed)`.
  ///
  /// **Do not simplify this back to a bare `readyState` read.** That is what is
  /// already here as the second condition, it was added in 04-08 *before* the
  /// flake was recorded in Phase 5, and it is the thing that did not hold. It
  /// stays because it is measured-correct for the other direction: across ~2
  /// million attempts after a *peer*-initiated close or a peer that vanished
  /// without a close frame, `readyState` never once read `open` over a sink
  /// that threw.
  bool _closing = false;

  /// `StateError`s the sink threw anyway, if the guards above ever let one
  /// through. Empty is the claim; the anti-vacuity arm in the meta group is
  /// what proves the guard rather than the catch is holding.
  final List<Object> swallowed = <Object>[];

  void result(int id, Object? value) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'result': value,
      });

  void hello(int id) => result(
        id,
        HelloResult(
          protocol: protocolVersion,
          server: const PeerInfo('fake-gateway', '0.0.1'),
          sessionId: 'S1',
          epoch: 'E1',
          serverTime: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      );

  void snapshot(int id, String sub) => result(id, {
        'sub': sub,
        'epoch': 'E1',
        'seq': 0,
        'handles': {_seededKey: 1},
        'snapshot': {'1': WireValue.of(true).toJson()},
      });

  void _send(Object? frame) {
    // Own intent first, then the socket's opinion. See [_closing] for why the
    // order is the whole fix and why the second condition stays.
    if (_closing) return;
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(frame));
    } on StateError catch (error) {
      // Belt and braces. The same window exists for any future self-close path
      // somebody adds here, and a fake gateway throwing at teardown is never
      // the finding — but it is recorded rather than dropped, because a guard
      // that has quietly stopped working looks exactly like one that works.
      swallowed.add(error);
    }
  }
}
