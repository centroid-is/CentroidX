/// **F23 — Ghost-session leak.** The catalogue row, verbatim from
/// `f_row_registry.dart` (§7.9 via 09-PATTERNS §0):
///
/// injection: connect client, `kill -9`, repeat ×200
/// expectation: gateway memory and upstream monitored-item count return to baseline
///
/// **The harness is copied from `tfc_relay_server/test/teardown_test.dart`**
/// (warm-up, the `[10, 50, 100, 200]` checkpoints, the held-session control,
/// the two alternating key sets, the settled descriptor count), named here as
/// the source because the copy needs a reason: the server half of this row
/// has been green in that file since Phase 3, and moving its two hundred kill
/// cycles into a package that builds native assets buys nothing. What that
/// file cannot say — and what this one adds — is the **upstream half**: its
/// plant is a `FakeStateMan` with no upstream boundary at all, while this
/// gateway's source is a real `LocalStateMan` over per-alias fake links, so
/// only here can `upstreamSubscriptionsCreated` answer whether two hundred
/// wash-down power cycles cost the PLC monitored items. The server-side half
/// is asserted still standing by a text read, never duplicated.
///
/// The three doctrines travel with the harness, restated from
/// `teardown_test.dart:7-27` because each has already earned its place:
///
///  * **The control arm is not decoration.** `expect(delta, 0)` passes
///    vacuously whenever the counter is broken, and the obvious fd counter
///    *is* easy to break — `lsof` exits 1 when no rows match, so the
///    reflexive `exitCode != 0` check turns the clean case into a failure.
///    The twenty deliberately-held panels hold every counter in this file to
///    that standard.
///  * **Checkpoints are a rate, not a number.** The delta at 10, 50, 100 and
///    200 turns "we leak" into "we leak one per cycle", which is the sentence
///    that names the missing release. A single assertion at the end says only
///    that something, somewhere, over two hundred cycles, went wrong.
///  * **TIME_WAIT needs no handling.** A TIME_WAIT socket holds a kernel
///    table entry, not a file descriptor; 1245 of them accumulated over a
///    100-cycle run without moving the count. No `SO_REUSEADDR` gymnastics.
///
/// The handle table is asserted **constant** rather than returned to
/// baseline: handles are permanent by 03-CONTEXT's ruling (reuse would hand a
/// reconnecting panel an integer that now means a different tag), and
/// permanence is only defensible while the table does not grow with churn —
/// so two distinct key sets alternate through the run, because a per-session
/// mint can hide behind a single repeated subscription.
///
/// Only the descriptor arm is Windows-skippable: `openSocketCount` needs
/// `/proc/self/fd` or `lsof`, and the registry, listener and handle-table
/// arms need neither — a skip on the row itself would make the row read as
/// judged on a column of the matrix where it never ran. So the descriptor
/// measurement lives in its own case, skipped per-test by the probe's own
/// named reason.
@TestOn('vm')
@Tags(['gate'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// The server-wide subscription and listener sums live on an extension over
// `SessionRegistry` that the barrel deliberately does not export (an embedder
// configures a server, it does not reach into a session). Imported from src
// on `poison_gate_test.dart`'s precedent (`error_codes.dart`): a gate case is
// exactly the reader those counters were written for.
import 'package:tfc_relay_server/src/subscription_registry.dart'
    show SessionSubscriptionCounts;
import 'package:tfc_stateman_contract/faults.dart'
    show FaultProxy, openSocketCount, openSocketCountSkipReason;

import '../support/gate_b_fixture.dart';

/// Cycles run before the baseline is taken.
///
/// The first few allocations are not a leak: the VM grows its own pools, the
/// server mints its handles for the first time, and `lsof` on macOS is a
/// subprocess whose plumbing settles. Five is what the server-side harness
/// measured a stable baseline after, and it is enough here for both key sets
/// to have been minted before the handle table's size is first read.
const _warmupCycles = 5;

/// Cumulative cycle counts at which every delta is asserted and printed.
const _checkpoints = <int>[10, 50, 100, 200];

/// Panels the control arm holds open for the whole run — the fixture's own
/// panels, real `RemoteStateMan`s over real sockets, present and subscribed
/// at every checkpoint. A counter that always answers zero must fail against
/// them.
const _held = 20;

/// The two aliases of the pipe, ten keys each: wide enough that the churn key
/// sets are a strict subset of a busy page, small enough that twenty held
/// panels do not turn a leak hunt into a throughput test.
const _aliases = <String>['ST101', 'ST201'];
const _keysPerAlias = 10;

/// The two key sets the churn alternates between.
///
/// Two rather than one because a fixed key set makes a per-session handle
/// mint invisible: with one set, a table that minted a fresh handle per
/// session and a table that returned the same handle every time are
/// indistinguishable by size alone only if the mint happens to reuse the row.
/// Both sets are inside the held panels' pages on purpose — twenty panels
/// watching these keys is what pins the fan-in refcount above zero, so a
/// churn cycle that mints anything upstream is a refcount that broke.
const _keySets = <List<String>>[
  [
    'ST101.CN01.MOT01.setpoint',
    'ST101.CN01.MOT02.setpoint',
    'ST101.CN02.MOT01.setpoint',
  ],
  [
    'ST201.CN01.MOT01.setpoint',
    'ST201.CN01.MOT02.setpoint',
  ],
];

/// Every key any cycle touches, for the listener-baseline readings.
final _churnKeys = [for (final set in _keySets) ...set];

const _sub = 'page-under-churn';

const _connectBudget = Duration(seconds: 5);
const _rpcBudget = Duration(seconds: 5);
const _reapBudget = Duration(seconds: 5);

/// A delta as a per-cycle rate, which is the sentence a failure needs to
/// name the missing release: "we leak" and "we leak one per cycle" are
/// different sentences.
String _rate(int delta, int cycles) => (delta / cycles).toStringAsFixed(2);

/// The hello a cycle client sends when it does not care about the details —
/// `ws_harness.dart:66-71`'s shape, copied because no `package:` URI reaches
/// another package's `test/`.
Map<String, Object?> _helloParams() => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-churn', '0.1.0'),
    ).toJson();

/// Counts open socket fds, after letting the kernel catch up.
///
/// Copied from `teardown_test.dart:120-127` with its reason: this is a
/// **measurement** delay rather than synchronisation — closing a socket is
/// asynchronous with respect to the descriptor actually closing, and there is
/// no event the kernel offers to say the fd table has settled. Written in the
/// unparameterised form on purpose: the sleep-hunting grep matches this
/// spelling and the generic form would hide from it.
Future<int> _countAfterSettle() async {
  // The measurement delay (see above).
  await Future.delayed(fdSettle);
  return openSocketCount();
}

/// Attached fan-in listeners for every key any cycle touches — the plant's
/// own count (`LocalStateMan.listenerCount`, 08-05), read as a delta against
/// a baseline because the held panels legitimately hold every churn key.
int _fanListenersOnChurnKeys(GateBFixture fixture) => [
      for (final key in _churnKeys) fixture.plant.listenerCount(key)
    ].fold(0, (a, b) => a + b);

/// Upstream subscription creates, summed across every link.
///
/// **A delta of creates, never a balance** (08-PLAN-INDEX freeze 7): one
/// logical OPC UA key is four monitored items and the binding discards the
/// delete future, so the balance the catalogue asks for does not exist —
/// the seeded F23 deviation in `f_row_registry.dart` quotes the clause and
/// carries the number this case measures.
int _createsOf(GateBFixture fixture) => [
      for (final link in fixture.links) link.upstreamSubscriptionsCreated
    ].fold(0, (a, b) => a + b);

/// The churn side of the pipe: one `FaultProxy` in front of the long-lived
/// gateway, one short-lived raw client per cycle dialled through it.
///
/// The proxy is what makes a kill abrupt — `killOnce` is `SO_LINGER{1,0}`
/// then `destroy()` on both halves of the pair, a genuine reset with no
/// WebSocket close handshake and no close code: the panel "sends nothing on
/// death", which is the wash-down power-cycle this row is about. A graceful
/// close would exercise a completely different path in the session. The held
/// panels dial the gateway's own port directly, so no kill can touch them.
final class _Churn {
  _Churn._(this.fixture, this.proxy, this.settleTo);

  final GateBFixture fixture;
  final FaultProxy proxy;

  /// The session count a settled gateway shows between cycles — the held
  /// panels, and nothing else.
  final int settleTo;

  int _keySetIndex = 0;

  static Future<_Churn> start(GateBFixture fixture,
      {required int settleTo}) async {
    final proxy = FaultProxy(targetPort: fixture.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
    return _Churn._(fixture, proxy, settleTo);
  }

  List<String> nextKeys() => _keySets[_keySetIndex++ % _keySets.length];

  /// Connects one raw client through the proxy and takes it through hello
  /// and subscribe, so the session it produces is holding real resources.
  ///
  /// A raw `dart:io` WebSocket speaking JSON-RPC by hand, on
  /// `poison_gate_test.dart` F28c's precedent — the cycle client's whole job
  /// is to die badly two lines later, and a `RemoteStateMan` would fight for
  /// its life (reconnect, backoff, resync) exactly where this harness needs
  /// a corpse.
  Future<_CycleClient> connect(List<String> keys) async {
    final ws = await within(
      WebSocket.connect('ws://127.0.0.1:${proxy.port}'),
      'a cycle client reaching the gateway',
      budget: _connectBudget,
    );
    final frames = <Map<String, Object?>>[];
    final sub = ws.listen(
      (frame) {
        if (frame is String) {
          frames.add((jsonDecode(frame) as Map).cast<String, Object?>());
        }
      },
      // Swallowed on purpose: the reset lands here as an error, and it is
      // the ordinary shape of the thing being tested rather than news — a
      // channel failure must fail the assertion that named the property,
      // not arrive as an unhandled zone error attributed to whichever case
      // happens to be running when it lands (teardown_test.dart:197-200).
      onError: (Object _) {},
      cancelOnError: false,
    );
    final client = _CycleClient(ws, sub, frames);

    ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': 'h',
      'method': Methods.hello,
      'params': _helloParams(),
    }));
    await until(
      'a cycle client\'s hello answered',
      () => client.answered('h'),
      budget: _rpcBudget,
    );
    ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': 's',
      'method': Methods.subscribe,
      'params': SubscribeParams(sub: _sub, keys: keys).toJson(),
    }));
    await until(
      'a cycle client\'s subscribe answered',
      () => client.answered('s'),
      budget: _rpcBudget,
    );
    return client;
  }

  /// Kills the live connection abruptly and waits for the gateway to let go.
  Future<void> killAndSettle(_CycleClient client) async {
    proxy.killOnce();
    await client.release();
    await until(
      'the gateway letting go of a killed cycle client',
      () => fixture.sessionCount == settleTo,
      budget: _reapBudget,
    );
  }

  /// One whole cycle: connect, subscribe, die without a close frame.
  Future<void> cycle() async => killAndSettle(await connect(nextKeys()));
}

/// One cycle's client, and the descriptors it owns.
final class _CycleClient {
  _CycleClient(this.ws, this._sub, this._frames);

  final WebSocket ws;
  final StreamSubscription<dynamic> _sub;
  final List<Map<String, Object?>> _frames;

  /// Whether a response frame carrying [id] has arrived.
  bool answered(String id) => _frames.any((frame) => frame['id'] == id);

  /// Releases this end. Every failure is swallowed: by the time this runs
  /// the far end has usually been reset out from under it, and that is the
  /// ordinary shape of the thing being tested rather than news.
  Future<void> release() async {
    await _sub.cancel();
    try {
      await ws.close();
    } catch (_) {
      // Already dead, which is the point.
    }
  }
}

void main() {
  test(
      'F23a: two hundred abrupt kill cycles leave the session registry, the '
      'attached listeners and the handle table where the warm-up left them — '
      'and twenty deliberately-held panels prove every counter can move',
      () async {
    final fixture = await gateBFixture(
      panels: _held,
      aliases: _aliases,
      keysPerAlias: _keysPerAlias,
      readyBudget: const Duration(seconds: 60),
    );
    final churn = await _Churn.start(fixture, settleTo: _held);

    for (var i = 0; i < _warmupCycles; i++) {
      await churn.cycle();
    }

    // 08-05's release-at-refcount-zero holds an armed timer for this long
    // after the last detach. Read from the gateway's own config rather than
    // restated, and printed so the checkpoint table carries it: every
    // upstream sample below waits it out first, so an armed release cannot
    // straddle a checkpoint read. (This fixture composes `LocalStateMan` at
    // its default, which is zero — shorter than any cycle.)
    final linger = fixture.plant.linger;
    print('F23 upstream release linger, from the gateway\'s own config: '
        '${linger.inMilliseconds} ms');

    final sessionsBaseline = fixture.sessionCount;
    final subsBaseline = fixture.server.sessions.subscriptionCount;
    final registryListenersBaseline = fixture.server.sessions.listenerCount;
    final fanListenersBaseline = _fanListenersOnChurnKeys(fixture);
    final handleBaseline = fixture.server.handles.size;
    final createsBaseline = _createsOf(fixture);
    print('F23 baseline after $_warmupCycles warm-up cycles: '
        '$sessionsBaseline sessions, $subsBaseline subscriptions, '
        '$registryListenersBaseline registry listeners, '
        '$fanListenersBaseline fan-in listeners on the churn keys, '
        '$handleBaseline handles, $createsBaseline upstream creates');

    // ------------------------------------------- the control arm, asserted
    // The twenty held panels are not decoration: without these floors every
    // "back to baseline" below passes for a leak-free gateway and for a
    // counter that always answers zero, and the second is the easier
    // mistake to make.
    expect(sessionsBaseline, _held,
        reason: 'the session counter saw $sessionsBaseline of $_held panels '
            'that are demonstrably connected and subscribed — a registry '
            'counter that cannot see the held panels judges nothing below');
    expect(subsBaseline, greaterThanOrEqualTo(_held),
        reason: 'the subscription counter saw $subsBaseline subscriptions '
            'across $_held held panels that each subscribed a whole page — '
            'a counter stuck at zero would make every checkpoint vacuous');
    expect(registryListenersBaseline,
        greaterThanOrEqualTo(_held * _churnKeys.length),
        reason: 'the registry-side listener sum saw '
            '$registryListenersBaseline listeners where $_held panels each '
            'hold at least the ${_churnKeys.length} churn keys — a listener '
            'counter stuck at its baseline would make "back to baseline" '
            'unfalsifiable');
    expect(fanListenersBaseline, greaterThanOrEqualTo(_churnKeys.length),
        reason: 'the fan-in holds one attachment per watched key however '
            'many panels watch it (08-05), so every churn key must be '
            'attached before the churn starts — a fan-in that counts nothing '
            'here would read a broken refcount as a clean run');
    expect(handleBaseline, greaterThanOrEqualTo(_churnKeys.length),
        reason: 'the warm-up must have minted both churn key sets before the '
            'table\'s size is frozen, or "constant" below would be asserting '
            'that a table nobody filled did not grow');
    expect(createsBaseline, greaterThanOrEqualTo(_churnKeys.length),
        reason: 'the held panels\' own subscriptions must have COST upstream '
            'creates before the churn starts — this is the arm that proves '
            'the counter is capable of being non-zero, so a flat delta below '
            'cannot be a counter that never counted anything');

    var completed = 0;
    for (final checkpoint in _checkpoints) {
      while (completed < checkpoint) {
        await churn.cycle();
        completed++;
      }

      // The linger is accounted for explicitly: an armed release timer from
      // the last cycle's detach must have fired (or been proven absent)
      // before the upstream sample is believed. Zero at this fixture's
      // config, so this is a no-op that documents the hazard.
      if (linger > Duration.zero) {
        await Future<void>.delayed(linger);
      }

      final sessions = fixture.sessionCount;
      final subs = fixture.server.sessions.subscriptionCount;
      final registryListeners = fixture.server.sessions.listenerCount;
      final fanListeners = _fanListenersOnChurnKeys(fixture);
      final handles = fixture.server.handles.size;
      // The close ledger is CAPPED at 64 (relay_server.dart:752-753), so it
      // is sampled at every checkpoint and never read once at the end — an
      // end-state read of a 200-cycle run sees only the last 64 closes.
      final evictions = fixture.evictions.length;
      final reaps = fixture.heartbeatReaps.length;
      final createsDelta = _createsOf(fixture) - createsBaseline;

      print('F23 upstream creates after +$completed kill cycles: '
          'delta $createsDelta (${_rate(createsDelta, completed)}/cycle)');
      print('F23 after +$completed kill cycles: '
          'sessions $sessions '
          '(${_rate(sessions - sessionsBaseline, completed)}/cycle), '
          'subscriptions $subs '
          '(${_rate(subs - subsBaseline, completed)}/cycle), '
          'registry listeners $registryListeners '
          '(${_rate(registryListeners - registryListenersBaseline, completed)}'
          '/cycle), '
          'fan-in listeners $fanListeners '
          '(${_rate(fanListeners - fanListenersBaseline, completed)}/cycle), '
          'handles $handles, '
          'ledger sample: $evictions evictions, $reaps heartbeat reaps');

      expect(sessions, sessionsBaseline,
          reason: 'after $completed abruptly killed panels the gateway holds '
              '${sessions - sessionsBaseline} sessions beyond the $_held held '
              'ones — read the checkpoints above as a rate: '
              '${_rate(sessions - sessionsBaseline, completed)} per cycle. '
              'One per cycle is a teardown path a reset never reaches, and a '
              'gateway that keeps a session per reconnect dies of memory '
              'after a day of flapping plant network — and this same number '
              'is the control arm: $_held here means the held panels are '
              'still present, so a counter answering zero fails loudly');
      expect(subs, subsBaseline,
          reason: 'a session can leave the registry and still have left its '
              'subscriptions attached — that is the leak the session count '
              'alone cannot see, at '
              '${_rate(subs - subsBaseline, completed)} per cycle. Equality '
              'with the baseline also asserts the held panels are still '
              'subscribed at this checkpoint, which is the control arm\'s '
              'other half');
      expect(registryListeners, registryListenersBaseline,
          reason: 'the live sessions\' summed listeners moved by '
              '${registryListeners - registryListenersBaseline} '
              '(${_rate(registryListeners - registryListenersBaseline, completed)} '
              'per cycle) against a churn that should return every listener '
              'it attached — a listener that outlives its session keeps '
              'pushing values into a buffer nobody will ever drain');
      expect(fanListeners, fanListenersBaseline,
          reason: 'the plant-side fan-in count moved by '
              '${fanListeners - fanListenersBaseline} '
              '(${_rate(fanListeners - fanListenersBaseline, completed)} per '
              'cycle) across the churn keys. Downward is a refcount released '
              'under panels still watching; upward is an attach with no '
              'matching detach — either way it is the 08-05 chain this row '
              'exists to hold');
      expect(createsDelta, 0,
          reason: 'the upstream monitored-item create-delta is '
              '$createsDelta after $completed kill cycles — '
              '${_rate(createsDelta, completed)} per cycle. This is the '
              'clause the catalogue wrote as "return to baseline", asserted '
              'in the only form the design offers (a delta of creates, '
              'never a balance — freeze 7, and the seeded F23 deviation): '
              'a positive rate means the refcount chain released items the '
              'held panels still watch and bought them back every cycle, '
              'which is how weeks of nightly wash-down reboots exhaust a '
              'PLC\'s hard monitored-item cap');
      expect(handles, handleBaseline,
          reason: 'the handle table went from $handleBaseline to $handles '
              'across $completed sessions over ${_keySets.length} distinct '
              'key sets. Handles are permanent by ruling (03-CONTEXT): reuse '
              'would hand a reconnecting panel an integer that now means a '
              'different tag. Permanence is only defensible while the table '
              'does not grow with churn, and a per-session mint would show '
              'as growth here and nowhere else');
      expect(evictions, 0,
          reason: 'the gateway evicted a panel during a run in which every '
              'death was the client\'s own — an abrupt kill must be observed '
              'as a transport death, never answered with an eviction code. '
              'Sampled from the capped ledger at this checkpoint, so the '
              'number reads on the last 64 closes');
      expect(reaps, 0,
          reason: 'a heartbeat reap in this run means a kill the transport '
              'never noticed: the reset should tear the session down in '
              'milliseconds, and a gateway that waits out the heartbeat '
              'deadline for every wash-down power-cycle holds every corpse '
              'for seconds. Sampled from the capped ledger at this '
              'checkpoint');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
      'F23b: two hundred abrupt kill cycles leave the process holding the '
      'sockets it started with — the descriptor count, settled before it is '
      'believed, in its own case so a Windows skip cannot take the registry '
      'arms with it',
      () async {
        final fixture = await gateBFixture(
          panels: 1,
          aliases: _aliases,
          keysPerAlias: _keysPerAlias,
        );
        final churn = await _Churn.start(fixture, settleTo: 1);

        for (var i = 0; i < _warmupCycles; i++) {
          await churn.cycle();
        }
        final fdBaseline = await _countAfterSettle();
        print('F23b baseline after $_warmupCycles warm-up cycles: '
            '$fdBaseline open sockets');

        // The fd counter's own control arm: hold connections open and watch
        // the number move, then release them and watch it come back. `lsof`
        // exits 1 when no rows match, so the naive exit-code check returns
        // nothing exactly when the clean case does — this is what makes that
        // failure loud.
        final heldClients = <_CycleClient>[];
        for (var i = 0; i < _held; i++) {
          heldClients.add(await churn.connect(churn.nextKeys()));
        }
        final fdHeld = await _countAfterSettle();
        print('F23b control: $_held held connections -> $fdHeld open sockets '
            '(delta ${fdHeld - fdBaseline})');
        expect(fdHeld - fdBaseline, greaterThanOrEqualTo(_held),
            reason: 'the socket counter saw ${fdHeld - fdBaseline} more '
                'descriptors while $_held connections were demonstrably held '
                'open through the proxy — a counter that cannot see them '
                'makes every zero below vacuous');
        for (final client in heldClients) {
          await client.release();
        }
        await until(
          'the gateway letting go of every released control client',
          () => fixture.sessionCount == 1,
          budget: _reapBudget,
        );
        final fdReleased = await untilSocketsSettle(fdBaseline);
        expect(fdReleased, fdBaseline,
            reason: 'the descriptor count did not come back down after the '
                'held connections were released, with the gateway still '
                'running: either the counter measures something that '
                'outlives the socket, or the gateway holds a connection '
                'after its client has gone — the leak at one session rather '
                'than at two hundred');

        var completed = 0;
        for (final checkpoint in _checkpoints) {
          while (completed < checkpoint) {
            await churn.cycle();
            completed++;
          }
          // A window rather than one reading after a sleep: `destroy()`
          // returns before the descriptor closes, and how long "before" is
          // depends on the runner.
          final fd = await untilSocketsSettle(fdBaseline);
          final delta = fd - fdBaseline;
          print('F23b after +$completed kill cycles: $fd open sockets '
              '(delta $delta, ${_rate(delta, completed)}/cycle)');
          expect(delta, 0,
              reason: 'after $completed kill cycles the process holds '
                  '$delta more socket descriptors than the baseline of '
                  '$fdBaseline — about ${_rate(delta, completed)} per cycle. '
                  'A gateway that leaks a descriptor per reconnect dies of '
                  'EMFILE; and TIME_WAIT is not the explanation, because a '
                  'TIME_WAIT socket holds a kernel table entry, not a '
                  'descriptor');
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      onPlatform: const {'windows': Skip(openSocketCountSkipReason)});

  test(
      'F23c: the gateway half of this row is still standing in '
      'tfc_relay_server — read as text, never duplicated', () {
    // The same relative-path crossing no_retry_test.dart:182-293 makes into
    // ../tfc_relay_server/lib, and the third use of the read-a-file-as-text
    // pattern (fault_contract_test.dart's registry read). Gate B asserts the
    // server-side half still exists and still names F23, because this file
    // deliberately does NOT repeat that half: two more hundred-cycle loops
    // against a FakeStateMan would prove nothing this package's pipe does
    // not already prove, and the criterion would then be judged twice with
    // neither reader sure which one counts.
    const serverHalf = '../tfc_relay_server/test/teardown_test.dart';
    final file = File(serverHalf);
    // The anti-vacuity guard, and it fails by PATH, not by content: a text
    // read of a file that is not there must never decay into "the doc no
    // longer names F23", because those are different faults with different
    // fixes.
    expect(file.existsSync(), isTrue,
        reason: 'no file at $serverHalf (resolved against '
            '${Directory.current.path}). The server half of F23 has moved or '
            'been renamed — find where it went and repoint this read; do not '
            'let the assertions below report on an empty string');

    final source = file.readAsStringSync();
    expect(source.split('\n').first, contains('F23'),
        reason: 'the server-side harness no longer opens its library doc by '
            'naming F23, so the claim that the gateway half of this row "has '
            'been green since Phase 3" no longer has a named owner — either '
            'the doc moved the name or the file no longer gates the row, and '
            'both belong in front of whoever edits it next');
    expect(source, contains('const _checkpoints = <int>[10, 50, 100, 200];'),
        reason: 'the server-side harness no longer declares the four '
            'checkpoints this file copied — the two halves of F23 have '
            'drifted, and "checkpoints are a rate" only holds while both '
            'sides sample at the same places');
    expect(source, contains('const _held = 20;'),
        reason: 'the server-side harness no longer declares its held-session '
            'control — the doctrine this file restates ("the control arm is '
            'not decoration") would then be quoting a file that dropped it');
  });
}
