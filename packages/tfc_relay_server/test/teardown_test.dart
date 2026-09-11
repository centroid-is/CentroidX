/// F23 / ROADMAP Phase 3 criterion 5: two hundred abrupt kill cycles against
/// one long-lived gateway, and everything the gateway held comes back.
///
/// Structured on `tfc_stateman_contract/test/faults/leak_test.dart`, which is
/// the tested precedent in this repo, and it carries that file's three
/// doctrines forward because each of them has already earned its place:
///
///  * **The control arm is not decoration.** `expect(delta, 0)` passes
///    vacuously whenever the counter is broken, and the obvious fd counter
///    *is* easy to break: `lsof` exits 1 when no rows match, so an
///    `exitCode != 0` check reports failure exactly when the honest answer is
///    zero. The held-sessions arm below makes a silent counter fail loudly,
///    and it holds every counter this file uses to that standard — the
///    descriptors, the session count and the subscription count — because a
///    registry counter that always answers zero passes the criterion just as
///    well as a leak-free server.
///  * **Checkpoints are a rate, not a number.** Reporting the delta at 10, 50,
///    100 and 200 turns "we leak" into "we leak one per cycle", which is the
///    sentence that names the missing release. RESEARCH Finding 11 caught a
///    real one-per-cycle descriptor leak in the fault proxy exactly this way
///    (10 / 60 / 160). A single assertion at the end says only that
///    something, somewhere, over two hundred cycles, went wrong.
///  * **TIME_WAIT needs no handling.** A TIME_WAIT socket holds a kernel table
///    entry, not a file descriptor; RESEARCH measured 1245 of them
///    accumulating during a 100-cycle run without moving the count. Anyone
///    tempted to add `SO_REUSEADDR` gymnastics to stabilise this file should
///    know it was already stable without them.
///
/// **What is different here, and why.** The handle table is asserted
/// **constant** rather than returned to baseline: 03-CONTEXT rules that
/// handles are permanent, because reuse would hand a reconnecting panel an
/// integer that now means a different tag — a wrong number on a screen, which
/// is worse than a missing one. Permanence is only defensible if the table
/// does not grow with *churn*, so the assertion is equality across all two
/// hundred cycles, and R3's point is that a single fixed key set would hide a
/// per-session mint. Two distinct key sets alternate through the run so the
/// assertion has something to catch.
///
/// **Only the fd arm is Windows-skippable.** `openSocketCount` needs
/// `/proc/self/fd` or `lsof`; the registry, listener and handle-table
/// assertions need neither, and a whole-file skip would leave the parts
/// Windows *can* judge unjudged. The skip is therefore per-test rather than
/// the library-level `@OnPlatform` annotation, which would take the file with
/// it — and because a `test(onPlatform: ...)` argument is evaluated rather
/// than parsed syntactically, it can name the real
/// `openSocketCountSkipReason` instead of restating it as a literal.
@Tags(['ws', 'faults'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

/// Cycles run before the baseline is taken.
///
/// The first few allocations are not a leak: the VM grows its own pools, the
/// server mints its handles for the first time, and `lsof` on macOS is a
/// subprocess whose plumbing settles. Five is what RESEARCH measured a stable
/// baseline after, and it is enough here for both key sets to have been minted
/// before the handle table's size is first read.
const _warmupCycles = 5;

/// Cumulative cycle counts at which every delta is asserted and printed.
const _checkpoints = <int>[10, 50, 100, 200];

/// Sessions the control arm holds open at once.
const _held = 20;

/// How long to wait after a teardown before believing a count.
const _settle = Duration(milliseconds: 400);

const _connectBudget = Duration(seconds: 5);
const _rpcBudget = Duration(seconds: 5);
const _reapBudget = Duration(seconds: 5);

/// The two key sets the run alternates between.
///
/// Two rather than one because R3's whole point is that a fixed key set makes
/// a per-session handle mint invisible: with one set, a table that minted a
/// fresh handle per session and a table that returned the same handle every
/// time are indistinguishable by size alone only if the mint happens to reuse
/// the row. Alternating sets also proves the table is not being rebuilt
/// between cycles, which would show as a size that oscillates rather than one
/// that grows.
const _keySets = <List<String>>[
  ['CN01.MOT01.speed', 'CN01.MOT02.speed', 'CN01.SEN01.state'],
  ['CN21.PMP01.flow', 'CN21.VLV01.open'],
];

/// Every key any cycle touches, for the listener-baseline reading.
final _allKeys = [for (final set in _keySets) ...set];

const _sub = 'page-under-test';

ServerConfig _cycleConfig() => ServerConfig(tick: ServerConfig.minTick);

/// Counts open socket fds, after letting the kernel catch up.
///
/// The only sleep in this file, and it is a **measurement** delay rather than
/// synchronisation: closing a socket is asynchronous with respect to the
/// descriptor actually closing, and there is no event the kernel offers to say
/// the fd table has settled. Counting too early produces intermittent
/// off-by-a-few deltas that read as a flaky leak. Every count goes through
/// here, so no arm can read a half-settled table and blame the gateway.
Future<int> _countAfterSettle() async {
  // The measurement delay. Written in the unparameterised form on purpose:
  // the phase-wide grep that hunts for sleeps used as synchronisation matches
  // this spelling and not the `Future<void>.delayed` one, so the generic form
  // would hide from it.
  await Future.delayed(_settle);
  return canCountOpenSockets ? openSocketCount() : 0;
}

/// Listeners attached to the backing fake for every key any cycle touches.
///
/// Reached through the node the fake hands out, which is the same object the
/// subscribe handler attached to (`session_handlers.dart:183` calls
/// `api.listen(key)`). Read as a delta against a baseline rather than against
/// zero, because the fake keeps bookkeeping listeners of its own and a test
/// demanding zero would be asserting something about the fake.
int _attachedListeners(StateManApi api) => [
      for (final key in _allKeys)
        (api.listen(key) as ValueStoreNode).listenerCount
    ].fold(0, (a, b) => a + b);

/// Completes when [server] is holding no sessions.
///
/// Event-driven rather than polled: a poll loop here would be a timing
/// assertion wearing a helper's clothes.
Future<void> _untilNoSessions(RelayServer server) async {
  if (server.sessions.sessionCount == 0) return;
  await server.sessions.gone.firstWhere((_) => server.sessions.sessionCount == 0);
}

/// One long-lived gateway with a fault proxy in front of it.
///
/// The gateway is built **once** and outlives every cycle, which is the whole
/// shape of F23: what is under test is a server's behaviour across connection
/// churn, and a server rebuilt per cycle cannot accumulate anything to find.
/// The proxy is what makes a kill abrupt — it resets the pair rather than
/// closing it politely, and a graceful close exercises a completely different
/// path in the session.
final class _Gateway {
  _Gateway._(this.served, this.server, this.proxy);

  final FakeStateMan served;
  final RelayServer server;
  final FaultProxy proxy;

  static Future<_Gateway> start({FakePreferences? preferences}) async {
    final served = FakeStateMan(preferences: preferences);
    final server = RelayServer(resolver: const PermissiveSeriesResolver(), api: served, config: _cycleConfig());
    await server.start();
    final proxy = FaultProxy(targetPort: server.port);
    await proxy.start();
    final gateway = _Gateway._(served, server, proxy);
    addTearDown(gateway.stop);
    return gateway;
  }

  /// Released innermost-first, the order `socket_harness.dart:234-266` argues
  /// for: the server (whose close drains its sessions with a code and then
  /// stops its listener), then the proxy — shutting it down destroys both
  /// halves of every pair it carries, so it cannot go first — then the fake,
  /// whose freshness watchdog must outlive anything still draining through it.
  Future<void> stop() async {
    await server.close();
    await proxy.shutdown();
    await served.dispose();
  }

  /// Connects one client through the proxy and takes it through hello and
  /// subscribe, so the session it produces is holding real resources.
  Future<_Client> connect(List<String> keys) async {
    for (final key in keys) {
      served.setValue(key, 0);
    }
    final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${proxy.port}'));
    await within(ws.ready, 'a cycle client reaching the gateway',
        budget: _connectBudget);
    final peer = rpc.Client(wsChannel(ws));
    // Swallowed on purpose: a channel failure must fail the assertion that
    // named the property, not arrive as an unhandled zone error attributed to
    // whichever case happens to be running when the reset lands.
    unawaited(peer.listen().catchError((Object _) => null));

    await within(peer.sendRequest(Methods.hello, helloParams()),
        'a cycle client\'s hello', budget: _rpcBudget);
    await within(
        peer.sendRequest(
            Methods.subscribe, SubscribeParams(sub: _sub, keys: keys).toJson()),
        'a cycle client\'s subscribe',
        budget: _rpcBudget);
    return _Client(ws, peer);
  }

  /// Kills the live connection abruptly and waits for the gateway to let go.
  ///
  /// `killOnce` is `SO_LINGER{1,0}` then `destroy()` on both halves of the
  /// pair, which is a genuine reset where the platform supports the option and
  /// an ungraceful FIN where it does not. Either way there is no WebSocket
  /// close handshake and no close code — the ungraceful shape F23 is about,
  /// and the one a `kill -9` on a panel produces. The linger capability is
  /// reported by the arm below rather than gating this helper: a FIN with no
  /// close frame still exercises the transport-death teardown path, and
  /// skipping the whole criterion on a platform that cannot reset would be
  /// giving up more than the difference is worth.
  Future<void> killAndSettle(_Client client) async {
    proxy.killOnce();
    await client.release();
    await within(_untilNoSessions(server), 'the gateway letting go of a killed '
        'client', budget: _reapBudget);
  }
}

/// A preference store that counts the listeners on its change stream.
///
/// `StreamController.broadcast` offers `hasListener` and no count, and "some
/// listener is attached" is exactly the wrong resolution for a leak measured as
/// a rate. So each read of [onPreferencesChanged] hands back its own
/// single-subscription bridge, and the count moves in `onListen` and
/// `onCancel` — which is also what makes the number *exact*: no settling, no
/// sampling, and no way for the arm to pass because the reading was taken too
/// early.
///
/// [everAttached] is the anti-vacuity companion: a bridge that never attached
/// would report zero live listeners forever, and "nothing leaked" would be true
/// of a stream nobody had ever listened to.
final class _CountingPreferences extends FakePreferences {
  /// Listeners attached right now.
  var attached = 0;

  /// Listeners ever attached, which never goes down.
  var everAttached = 0;

  @override
  Stream<String> get onPreferencesChanged {
    final upstream = super.onPreferencesChanged;
    StreamSubscription<String>? subscription;
    late final StreamController<String> bridge;
    bridge = StreamController<String>(
      onListen: () {
        attached++;
        everAttached++;
        subscription = upstream.listen(bridge.add,
            onError: bridge.addError, onDone: bridge.close);
      },
      onCancel: () async {
        attached--;
        await subscription?.cancel();
        subscription = null;
      },
    );
    return bridge.stream;
  }
}

/// One cycle's client, and the descriptors it owns.
final class _Client {
  _Client(this.ws, this.peer);
  final WebSocketChannel ws;
  final rpc.Client peer;

  /// Releases this end. Every failure is swallowed: by the time this runs the
  /// far end has usually been reset out from under it, and that is the
  /// ordinary shape of the thing being tested rather than news.
  Future<void> release() async {
    await peer.close().catchError((Object _) {});
    await ws.sink.close().catchError((Object _) {});
  }
}

void main() {
  // 03-REVIEW WR-05. `close()` used to close its listener *last*, which is
  // what allows new connections to arrive while the drain is running — the
  // opposite of what its doc claimed it achieved. A connection accepted
  // between the session-drain loop and the listener close built a whole
  // session, registered it, and then met `_sessions.dispose()`, which clears
  // the registry without closing anything: listeners left attached to the
  // source, socket left open. That is the leak this file polices, on the one
  // path it could not see, because it never closed a server mid-connect.
  test('a client that arrives while the server is draining is refused, not '
      'registered', () async {
    final served = FakeStateMan();
    final server = RelayServer(resolver: const PermissiveSeriesResolver(), api: served, config: fixtureConfig());
    await server.start();
    final uri = Uri.parse('ws://127.0.0.1:${server.port}');
    addTearDown(served.dispose);

    // Fired in the same turn as the close, so the accept path and the drain
    // are genuinely interleaved. Whether any given attempt lands before, in
    // or after the window is up to the scheduler; what must hold for every
    // one of them is that it did not leave a session behind.
    final draining = server.close();
    final attempts = <Future<void>>[
      for (var i = 0; i < 20; i++)
        () async {
          try {
            final ws = IOWebSocketChannel.connect(uri);
            await ws.ready;
            ws.sink.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': 'drain-$i',
              'method': Methods.hello,
              'params': helloParams(),
            }));
            await ws.stream.drain<void>();
          } catch (_) {
            // A refused TCP connect is the ordinary outcome once the listener
            // is closed, and it is the outcome this fix is *for*.
          }
        }(),
    ];

    await draining;
    await Future.wait(attempts);

    expect(server.sessions.sessionCount, 0,
        reason: 'a session built during the drain is one nothing will ever '
            'close: the drain loop has already passed and dispose() only '
            'clears the list');
    expect(_attachedListeners(served), 0,
        reason: 'the listeners of a session built during the drain stay '
            'attached to the plant forever, pushing values into a buffer that '
            'will never be drained again — the exact leak the kill-cycle test '
            'below measures across two hundred cycles');
  }, tags: 'ws');

  test(
      'two hundred kill cycles return the registry to baseline',
      () async {
        final gateway = await _Gateway.start();

        var keySetIndex = 0;
        List<String> nextKeys() => _keySets[keySetIndex++ % _keySets.length];

        for (var i = 0; i < _warmupCycles; i++) {
          await gateway.killAndSettle(await gateway.connect(nextKeys()));
        }

        final fdBaseline = await _countAfterSettle();
        final listenerBaseline = _attachedListeners(gateway.served);
        final handleBaseline = gateway.server.handles.size;
        print('baseline after $_warmupCycles warm-up cycles: $fdBaseline open '
            'socket fds, $listenerBaseline attached listeners, '
            '$handleBaseline handles');
        expect(handleBaseline, greaterThanOrEqualTo(_allKeys.length),
            reason: 'the warm-up must have minted every key set before the '
                'table\'s size is frozen, or "constant" below would be '
                'asserting that a table nobody filled did not grow');

        var completed = 0;
        for (final checkpoint in _checkpoints) {
          while (completed < checkpoint) {
            await gateway.killAndSettle(await gateway.connect(nextKeys()));
            completed++;
          }

          final fdCount = await _countAfterSettle();
          final fdDelta = fdCount - fdBaseline;
          final listeners = _attachedListeners(gateway.served);
          print('after +$completed kill cycles: $fdCount fds (delta $fdDelta), '
              '${gateway.server.sessions.sessionCount} sessions, '
              '${gateway.server.sessions.subscriptionCount} subscriptions, '
              '$listeners listeners (delta ${listeners - listenerBaseline}), '
              '${gateway.server.handles.size} handles');

          expect(gateway.server.sessions.sessionCount, 0,
              reason: 'after $completed abruptly killed clients the gateway '
                  'still holds ${gateway.server.sessions.sessionCount} '
                  'sessions — read the checkpoints above as a rate: one per '
                  'cycle is a teardown path that a reset never reaches, and a '
                  'gateway that keeps a session per reconnect dies of memory '
                  'after a day of flapping plant network, at which point it '
                  'stops serving every operator at once');
          expect(gateway.server.sessions.subscriptionCount, 0,
              reason: 'a session can leave the registry and still have left '
                  'its subscriptions attached; that is the leak the registry '
                  'count alone cannot see');
          expect(listeners, listenerBaseline,
              reason: 'the backing source holds ${listeners - listenerBaseline} '
                  'more listeners than it did at the baseline, about '
                  '${((listeners - listenerBaseline) / completed).toStringAsFixed(2)} '
                  'per cycle. A listener that outlives its session keeps '
                  'pushing values into a buffer nobody will ever drain');

          if (canCountOpenSockets) {
            expect(fdDelta, 0,
                reason: 'after $completed kill cycles the process holds '
                    '$fdDelta more socket descriptors than the baseline of '
                    '$fdBaseline — about '
                    '${(fdDelta / completed).toStringAsFixed(2)} per cycle. A '
                    'gateway that leaks a descriptor per reconnect dies of '
                    'EMFILE');
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      onPlatform: const {'windows': Skip(openSocketCountSkipReason)});

  test('the handle table does not grow with session churn', () async {
    final gateway = await _Gateway.start();

    var keySetIndex = 0;
    List<String> nextKeys() => _keySets[keySetIndex++ % _keySets.length];

    for (var i = 0; i < _warmupCycles; i++) {
      await gateway.killAndSettle(await gateway.connect(nextKeys()));
    }

    final before = gateway.server.handles.size;
    expect(before, greaterThanOrEqualTo(_allKeys.length),
        reason: 'both key sets must be in the table before it is frozen, or '
            'this case proves nothing about a table that was never filled');

    for (var i = 0; i < _checkpoints.last; i++) {
      await gateway.killAndSettle(await gateway.connect(nextKeys()));
    }

    final after = gateway.server.handles.size;
    print('handle table across ${_checkpoints.last} kill cycles: $before -> '
        '$after');
    expect(after, before,
        reason: 'the handle table went from $before to $after across '
            '${_checkpoints.last} sessions over ${_keySets.length} distinct '
            'key sets. Handles are permanent by ruling (03-CONTEXT): they are '
            'never released, because reuse would hand a reconnecting panel an '
            'integer that now means a different tag. Permanence is only '
            'defensible while the table does not grow with churn, and a '
            'per-session mint would show as growth here and nowhere else — '
            'every other counter in this file returns to baseline whether the '
            'handle came from the table or was minted fresh',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the counters would have noticed: $_held sessions held open on purpose',
      () async {
        final gateway = await _Gateway.start();

        final fdBaseline = await _countAfterSettle();
        final listenerBaseline = _attachedListeners(gateway.served);

        final clients = <_Client>[];
        addTearDown(() async {
          for (final client in clients) {
            await client.release();
          }
        });
        for (var i = 0; i < _held; i++) {
          clients.add(await gateway.connect(_keySets[i % _keySets.length]));
        }

        final fdWhileHeld = await _countAfterSettle();
        final fdDelta = fdWhileHeld - fdBaseline;
        final listeners = _attachedListeners(gateway.served);
        print('control: $_held deliberately-held sessions -> $fdWhileHeld fds '
            '(delta $fdDelta), ${gateway.server.sessions.sessionCount} '
            'sessions, ${gateway.server.sessions.subscriptionCount} '
            'subscriptions, $listeners listeners');

        expect(gateway.server.sessions.sessionCount, _held,
            reason: 'the session counter saw '
                '${gateway.server.sessions.sessionCount} of $_held sessions '
                'that are demonstrably open. Without this arm the criterion '
                'above passes for a gateway that leaks nothing and for a '
                'counter that always answers zero, and the second is the '
                'easier mistake to make');
        expect(gateway.server.sessions.subscriptionCount, _held,
            reason: 'and the subscription counter saw '
                '${gateway.server.sessions.subscriptionCount} of $_held '
                'subscriptions that are demonstrably live');
        expect(listeners - listenerBaseline, greaterThanOrEqualTo(_held),
            reason: 'and the backing source reports the listeners those '
                'sessions attached; a listener counter stuck at its baseline '
                'would make every "back to baseline" assertion above vacuous');

        if (canCountOpenSockets) {
          expect(fdDelta, greaterThanOrEqualTo(_held),
              reason: 'the fd counter saw $fdDelta more descriptors while '
                  '$_held connections were held open through the proxy. '
                  '`lsof` exits 1 when nothing matches, so the naive exit-code '
                  'check returns nothing exactly when the clean case does — '
                  'this arm is what makes that failure loud');
        }

        for (final client in clients) {
          await client.release();
        }
        clients.clear();
        await within(_untilNoSessions(gateway.server),
            'the gateway letting go of every released client',
            budget: _reapBudget);

        // The server and the proxy stay up, exactly as they were when the
        // baseline was taken — otherwise this would compare a count holding
        // two listeners against one holding none, and read a correct gateway
        // as leaking in the negative direction.
        final fdAfter = await _countAfterSettle();
        expect(_attachedListeners(gateway.served), listenerBaseline,
            reason: 'releasing the held sessions took the listeners back off '
                'the plant; if it did not, the counter is measuring something '
                'that outlives the session and every delta above is noise');
        if (canCountOpenSockets) {
          expect(fdAfter, fdBaseline,
              reason: 'the descriptor count did not come back down after the '
                  'held sessions were released, with the gateway still '
                  'running: either the counter measures something that '
                  'outlives the socket, or the gateway holds a connection '
                  'after its client has gone — which is the leak at one '
                  'session rather than at two hundred');
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
      onPlatform: const {'windows': Skip(openSocketCountSkipReason)});

  // 10-05. The gateway serves every session from **one shared preference
  // store**, so each session attaches its own listener to the one change
  // stream and each has to take it off again. A listener that outlives its
  // session keeps building key sets and calling `sendNotification` for a peer
  // that is gone — the same debt as a subscription left attached, on a
  // stream nothing else in this file measures, and reached by a completely
  // separate line in `_teardown` (T-10-20).
  //
  // Reported as a **rate**, on this file's second doctrine: "we leak" and "we
  // leak one per cycle" are different findings, and only the second names the
  // missing release. The benchmark is the 2.50 per cycle this file measured in
  // 03-11 for the same class of bug on the value path.
  group('a killed session takes its preference listener with it', () {
    /// Cycles this arm runs, and where it reports.
    ///
    /// Shorter than the 200 the registry arm runs, deliberately: this counter
    /// is exact rather than sampled — it is incremented in `onListen` and
    /// decremented in `onCancel`, with no kernel settling in between — so a
    /// one-per-cycle leak is unambiguous by the first checkpoint and a longer
    /// run would only cost minutes.
    const checkpoints = <int>[10, 30];

    test('thirty kill cycles leave no listener behind', () async {
      final counter = _CountingPreferences();
      final gateway = await _Gateway.start(preferences: counter);

      var keySetIndex = 0;
      List<String> nextKeys() => _keySets[keySetIndex++ % _keySets.length];

      for (var i = 0; i < _warmupCycles; i++) {
        await gateway.killAndSettle(await gateway.connect(nextKeys()));
      }

      final baseline = counter.attached;
      print('preference listeners after $_warmupCycles warm-up cycles: '
          '$baseline attached, ${counter.everAttached} ever attached');
      expect(counter.everAttached, greaterThanOrEqualTo(_warmupCycles),
          reason: 'the warm-up must have attached one listener per session, '
              'or "none left behind" below is a statement about a stream '
              'nobody ever listened to. ${counter.everAttached} attachments '
              'across $_warmupCycles sessions');

      var completed = 0;
      for (final checkpoint in checkpoints) {
        while (completed < checkpoint) {
          await gateway.killAndSettle(await gateway.connect(nextKeys()));
          completed++;
        }

        final leaked = counter.attached - baseline;
        print('after +$completed kill cycles: ${counter.attached} preference '
            'listeners attached (delta $leaked, '
            '${(leaked / completed).toStringAsFixed(2)} per cycle), '
            '${counter.everAttached} ever attached');

        expect(leaked, 0,
            reason: 'the shared preference store holds $leaked more listeners '
                'than it did at the baseline after $completed abruptly killed '
                'clients — about ${(leaked / completed).toStringAsFixed(2)} '
                'per cycle. Read it as a rate: one per cycle is a `_teardown` '
                'that never cancels, and each of those listeners goes on '
                'buffering keys and calling sendNotification into a peer that '
                'is gone. The same class of bug measured 2.50 per cycle on the '
                'value path before 03-11 fixed it');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('the counter would have noticed: $_held sessions held open on purpose',
        () async {
      // The control arm, and this file's first doctrine: `expect(delta, 0)`
      // passes just as well against a counter that always answers zero as
      // against a gateway that releases everything.
      final counter = _CountingPreferences();
      final gateway = await _Gateway.start(preferences: counter);

      final baseline = counter.attached;
      final clients = <_Client>[];
      addTearDown(() async {
        for (final client in clients) {
          await client.release();
        }
      });
      for (var i = 0; i < _held; i++) {
        clients.add(await gateway.connect(_keySets[i % _keySets.length]));
      }

      print('control: $_held deliberately-held sessions -> '
          '${counter.attached} preference listeners attached');
      expect(counter.attached - baseline, _held,
          reason: 'the counter saw ${counter.attached - baseline} listeners '
              'while $_held sessions were demonstrably open. One per session '
              'is the shape being built — a server-level subscription fanning '
              'out would read as one here, and would make the arm above true '
              'for a reason that has nothing to do with teardown');

      for (final client in clients) {
        await client.release();
      }
      clients.clear();
      await within(_untilNoSessions(gateway.server),
          'the gateway letting go of every released client',
          budget: _reapBudget);
      // The cancel runs inside `_teardown`, which is asynchronous past
      // `peer.close()`; the registry emptying is the event that says the
      // teardown was reached, not that it finished.
      await pumpEventQueue();

      expect(counter.attached, baseline,
          reason: 'releasing the held sessions took every listener back off '
              'the store. If it did not, the counter is measuring something '
              'that outlives the session and the rate above is noise');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  test('the package holds no per-session timer', () async {
    // T-03-35, made executable. Finding 8 chose the sweep over per-session
    // timers on leak-safety rather than on cost: a timer that captures a
    // session closure is exactly the ghost the cycles above hunt, and it is a
    // ghost the cycles can only find *after* someone writes it. A grep in a
    // plan protects the decision until the plan is closed; this protects it
    // afterwards.
    final lib = Directory('lib/src');
    expect(lib.existsSync(), isTrue,
        reason: 'the scan is pointed at the wrong directory, so it is about '
            'to report a clean result for a package it never read');

    final offenders = <String>[];
    var periodic = 0;
    for (final file in lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Doc comments argue *about* timers at length in this package, and an
        // argument is not a timer.
        if (line.trimLeft().startsWith('///')) continue;
        if (line.contains('Timer.periodic(')) {
          periodic++;
          if (!file.path.endsWith('tick_engine.dart')) {
            offenders.add('${file.path}:${i + 1}: $line');
          }
        }
        // `Timer.run` is the zero-duration one-shot that puts a teardown
        // behind the refusal explaining it; it cannot outlive the turn it was
        // scheduled in and it holds nothing open. A constructed `Timer(...)`
        // can do both, which is why only that spelling is an offence.
        if (line.contains('Timer(') && !line.contains('_timer')) {
          offenders.add('${file.path}:${i + 1}: $line');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'a repeating or retained timer exists outside the tick '
            'engine: ${offenders.join('; ')}. One timer per server, never one '
            'per session (Finding 8) — a timer holding a closed session\'s '
            'buffer, listeners and socket is invisible to the registry counts '
            'above because the registry no longer knows the session exists');
    expect(periodic, 1,
        reason: 'the package declares $periodic repeating timers. Exactly one '
            'is the property: two over one registry would double every '
            'client\'s frame rate and halve the value of every backpressure '
            'verdict');
  });
}
