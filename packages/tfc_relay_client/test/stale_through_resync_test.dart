@TestOn('vm')

/// The badge that cleared before the data behind it did.
///
/// Source: 16-10, finding S9 (WSH-05), verified at source before a line was
/// written.
///
/// `viewIsStale` is the one surface an operator uses to decide whether to trust
/// the screen. It was driven from `FreshnessWatchdog.sawFrame`, which does two
/// jobs in one call: it restarts the **link** deadline (the half-open detector)
/// and it clears the **view** badge. Those are different claims, and the
/// difference is invisible until a resync takes real time.
///
/// The order, as it ran:
///
/// 1. `_enter(LinkState.resyncing)`
/// 2. the `hello` RPC is awaited and answers
/// 3. `watchdog.sawFrame(InboundFrame.rpcResponse)` — **the badge clears here**
/// 4. `_resync.onHello(...)` → per page, sequentially: `subscribe`, then
///    `store.clear()`, then `store.applyBatch(snapshot)`
/// 5. `_enter(LinkState.ready)`
///
/// Between (3) and the end of (4) every page still holds its pre-outage values,
/// under `Quality.good`, with a badge saying the view is fresh. After a
/// sixty-second outage that is a minute-old number displayed as current, and it
/// is not a millisecond of it: the snapshots land one page at a time, each
/// behind its own subscribe round trip, on the multi-page slow link this client
/// was designed for. **16-01 made the window wider**, deliberately and
/// correctly, by giving snapshots a payload-scaled deadline instead of a ping's.
///
/// ## What moves, and the three things that must not
///
/// Only the **fresh** direction moves, to `_enter(LinkState.ready)` — which by
/// construction is reached only after `onHello` returned with every page's
/// store cleared and its snapshot adopted.
///
/// * **The link deadline still restarts on every inbound frame**, including the
///   hello and subscribe responses. Arm 3 is the pin. A "fix" that simply
///   deleted `sawFrame` from those two sites would make a long multi-page
///   resync trip the half-open detector and tear down the connection that was
///   succeeding — a worse bug than the one being fixed, and a self-sustaining
///   one, because `backoff.reset()` is reachable only from `_enter(ready)`.
/// * **The stale direction stays where it is.** `_linkWentQuiet` is a different
///   property on a different timer and `stall_gate_test.dart:41-49` documents
///   it.
/// * **The badge stays link-level.** `latency_gate_test.dart:146-161` is
///   emphatic that `viewFreshness` and `staleSubscriptions` are deliberately
///   independent verdicts — the per-subscription set can be non-empty while the
///   link is provably healthy. Coupling the badge to store contents is the
///   tempting shortcut and arm 4 is the pin against it. The fix is about *when*
///   the badge clears, not about *what* it measures.
///
/// ## Arm 1 is NEGATIVE, so read this before changing it
///
/// "`viewIsStale` never reads false while a page still holds pre-outage data"
/// goes **vacuously green** on a client that is permanently stale. Plan 14-13
/// learned that the hard way. Arm 2 is its load-bearing companion and the pair
/// only means something together: the sabotage runs in both directions, and a
/// collapse that never clears the badge must turn **arm 2** red.
///
/// The arms assert on the `viewFreshness` **event stream**, not on instant
/// reads. `half_open_gate_test.dart:183` records that an instant read of this
/// surface is a wall clock rendered as a bool, and `gate_manifest_test.dart:150`
/// bans instant reads of it for that reason. Each event is classified
/// **synchronously, inside the callback**, against whether every page was
/// holding its new snapshot at that instant — so the verdict is not a race
/// between a sampler and a socket.
///
/// What breaks in the plant without this file: the link to the packing hall
/// drops for a minute, the panel reconnects, the badge goes green while all
/// four pages still show the numbers from before the drop, and the operator
/// reads a minute-old weight as current.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// Two pages, because the finding is about the window *between* their
/// snapshots. One page would close the gap the arms are about.
const List<String> _pages = ['p1', 'p2'];
const Map<String, String> _keyOf = {
  'p1': 'ST101.CN01.MOT01.temperature',
  'p2': 'ST201.PCK01.SCL01.weight',
};
const int _handle = 1;

/// The number on the screen before the outage, and the number the plant moved
/// to during it. The difference is what makes "still holding pre-outage data" a
/// fact a callback can read rather than a guess about timing.
const int _beforeOutage = 1200;
const int _duringOutage = 1300;

const int _snapshotSeq = 4;
const Duration _budget = Duration(seconds: 25);
const Duration _settle = Duration(milliseconds: 400);

/// Long enough that an arm can leave the link silent while a slow snapshot
/// crosses it without the watchdog tearing the socket down — except in arm 3,
/// where exceeding it deliberately is the whole subject.
const Duration _freshness = Duration(milliseconds: 700);

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      snapshotDeadline: const Duration(seconds: 10),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: _freshness,
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    );

// ---------------------------------------------------------------------------
// The gateway.
// ---------------------------------------------------------------------------

/// A two-page gateway that can be told to answer `subscribe` slowly, and to
/// drop the link.
///
/// `_SlowGateway`'s sibling (`snapshot_deadline_test.dart:79`), copied for the
/// reason that file gives, with the two differences these arms need: it serves
/// **two** pages, and it can [dropLink] so an outage is a real socket loss
/// rather than a simulated one.
final class _ResyncGateway {
  _ResyncGateway._(this._http);

  static Future<_ResyncGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _ResyncGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many `hello` calls have been answered — i.e. how many sockets the
  /// panel has established. Arm 3's whole observable: a half-open teardown
  /// mid-resync shows up here as a second handshake.
  int hellos = 0;

  /// How many `subscribe` calls have been answered.
  int subscribes = 0;

  /// How long each `subscribe` answer is held back. The lever: a snapshot is
  /// answered correctly and slowly, which is what a congested plant link is.
  Duration subscribeDelay = Duration.zero;

  /// The value the next snapshot carries — moved during an outage so an arm can
  /// tell a page holding its new snapshot from one still holding the old.
  Object? snapshotValue = _beforeOutage;

  /// Bumped per answer, as the real registry mints one generation per
  /// establishment.
  int generation = 0;

  /// Whether the gateway is unreachable: every dial is accepted and then
  /// dropped without a `hello` being answered.
  ///
  /// **Without this there is no outage.** Closing the socket alone is not one:
  /// the panel redials on a 40 ms backoff and is back before the freshness
  /// deadline has run, so the badge never goes stale and the arms below record
  /// an empty window and pass on it. That is exactly the vacuous shape this
  /// file's header warns about, and it is how these two arms first passed
  /// against the unfixed client. An outage is a period in which the panel
  /// *cannot* get back, which is what a cut fibre is.
  bool down = false;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      if (down) {
        unawaited(socket.close().catchError((Object _) => null));
        continue;
      }
      _link = socket;
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          switch (method) {
            case Methods.hello:
              hellos++;
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('resync-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              final sub =
                  ((frame['params'] as Map)['sub'] as Object?).toString();
              final answer = {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': sub,
                  'epoch': 'E1',
                  'seq': _snapshotSeq,
                  'generation': ++generation,
                  'handles': {_keyOf[sub]!: _handle},
                  'snapshot': {
                    '$_handle': WireValue.of(snapshotValue).toJson(),
                  },
                },
              };
              if (subscribeDelay == Duration.zero) {
                _send(answer);
              } else {
                // The socket this answer belongs to, captured now: by the time
                // the delay elapses the panel may have hung up and dialled
                // again, and writing the old answer down the new socket would
                // be this harness inventing a frame nothing sent.
                final owner = _link;
                Timer(subscribeDelay, () => _sendOn(owner, answer));
              }
            default:
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32601, 'message': 'no such method'},
              });
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  /// A tick for every page, each claiming it was evaluated [staleBy] ago in the
  /// gateway's own clock.
  ///
  /// Zero is the healthy shape. A large value is arm 4's instrument: it makes
  /// the **per-subscription** verdict go stale on a link that is demonstrably
  /// answering, which is the exact situation the two verdicts are supposed to
  /// disagree about.
  void tick({Duration staleBy = Duration.zero}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _send({
      'jsonrpc': '2.0',
      'method': Methods.tick,
      'params': {
        'serverTime': now,
        'subs': {
          for (final page in _pages)
            page: {
              'seq': _snapshotSeq,
              'evaluatedAt': now - staleBy.inMilliseconds,
            },
        },
      },
    });
  }

  /// Kills the socket under the panel. A real close, so the client takes the
  /// path it takes in the plant.
  Future<void> dropLink() async {
    final socket = _link;
    _link = null;
    await socket?.close().catchError((Object _) => null);
  }

  void _send(Object? frame) => _sendOn(_link, frame);

  void _sendOn(WebSocket? socket, Object? frame) {
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    await _link?.close().catchError((Object _) => null);
    await _http.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// The panel.
// ---------------------------------------------------------------------------

/// One `viewFreshness` event, classified at the instant it was emitted.
typedef _Event = ({
  /// What the badge changed to.
  bool stale,

  /// Whether **every** page was holding its post-outage snapshot right then.
  ///
  /// Computed synchronously inside the callback, which is what makes this arm a
  /// statement about ordering rather than a race between a sampler and a
  /// socket.
  bool allPagesCurrent,

  /// How many pages were still holding a pre-outage number, for the failure
  /// message.
  int pagesStillOld,
});

typedef _Panel = ({
  ConnectionSupervisor supervisor,
  FreshnessWatchdog watchdog,
  Map<String, SubscriptionState> subscriptions,
  Map<String, ValueStore> stores,
  List<_Event> events,
});

/// Builds a two-page panel pointed at [gateway] and starts it.
///
/// **A store per page, not one shared.** `ResyncEngine._establish` calls
/// `store.clear()` per subscription; sharing one store would have page 1's
/// clear wipe page 2, which is precisely the state these arms are trying to
/// observe the absence of.
Future<_Panel> _panelOn(_ResyncGateway gateway, {bool establish = true}) async {
  final config = _config();
  final subscriptions = <String, SubscriptionState>{
    for (final page in _pages)
      page: SubscriptionState(subId: page, keys: {_keyOf[page]!}),
  };
  final stores = <String, ValueStore>{
    for (final page in _pages) page: ValueStore(),
  };
  for (final store in stores.values) {
    addTearDown(store.dispose);
  }

  final events = <_Event>[];
  bool holdsCurrent(String page) =>
      stores[page]!.node(_keyOf[page]!).value.value == _duringOutage;

  final watchdog = FreshnessWatchdog(
    config: config,
    onViewFreshnessChanged: (stale) {
      final old = _pages.where((page) => !holdsCurrent(page)).length;
      events.add((
        stale: stale,
        allPagesCurrent: old == 0,
        pagesStillOld: old,
      ));
    },
  );

  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: config,
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(milliseconds: 200),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog: watchdog,
    subscriptions: subscriptions,
    storeFor: (sub) => stores[sub]!,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  if (establish) {
    await _until(
        'both pages to be established',
        () => _pages.every((page) => subscriptions[page]!.lastSeq != null));
  }
  return (
    supervisor: supervisor,
    watchdog: watchdog,
    subscriptions: subscriptions,
    stores: stores,
    events: events,
  );
}

Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The scenario arms 1 and 2 share: establish two pages, lose the link for
/// long enough that the badge really does go stale, move the plant while it is
/// down, then let it come back with **slow** subscribe answers so the resyncing
/// window is wide.
Future<_Panel> _outageAndRecovery() async {
  final gateway = await _ResyncGateway.start();
  final panel = await _panelOn(gateway);

  // Anti-vacuity: the pages have to be holding the *old* number before an arm
  // about "still holding the old number" means anything.
  for (final page in _pages) {
    expect(panel.stores[page]!.node(_keyOf[page]!).value.value, _beforeOutage,
        reason: 'the page must hold its pre-outage value before the outage');
  }

  // A quiet plant still ticks, and the tick is what keeps the link deadline fed
  // while nothing is moving. Without it the badge goes stale on its own 700 ms
  // after establishment and the record below is about that, not about the
  // outage.
  final ticking =
      Timer.periodic(const Duration(milliseconds: 100), (_) => gateway.tick());
  addTearDown(ticking.cancel);
  await Future<void>.delayed(_settle);
  expect(panel.events, isEmpty,
      reason: 'the badge must be quiet before the outage, or the transitions '
          'recorded below are not the ones under test');

  // The outage. Not just a closed socket: the gateway becomes unreachable, so
  // the panel cannot simply redial past the freshness deadline.
  gateway.down = true;
  ticking.cancel();
  await gateway.dropLink();
  // The plant kept running while the panel could not see it.
  gateway.snapshotValue = _duringOutage;
  // Each page's snapshot now costs a real round trip, which is what makes the
  // window between the hello and the last snapshot wide enough to see.
  gateway.subscribeDelay = const Duration(milliseconds: 350);

  // `_linkWentQuiet` fires here, which is what puts the badge into the stale
  // state these arms are about it leaving.
  await _until('the badge to go stale', () => panel.watchdog.viewIsStale);
  expect(panel.events.map((e) => e.stale), [true],
      reason: 'one `true`, and nothing else yet: the window under test opens '
          'here');

  // The link comes back.
  gateway.down = false;

  await _until(
      'both pages to hold their post-outage snapshot',
      () => _pages.every((page) =>
          panel.stores[page]!.node(_keyOf[page]!).value.value ==
          _duringOutage));

  // The quiet plant resumes ticking, so the settle below measures what the
  // badge did about the recovery rather than what it does about a link nobody
  // is feeding.
  final settled =
      Timer.periodic(const Duration(milliseconds: 100), (_) => gateway.tick());
  addTearDown(settled.cancel);
  await Future<void>.delayed(_settle);
  settled.cancel();
  return panel;
}

void main() {
  group('the badge holds until the data behind it is replaced', () {
    test('no page is showing pre-outage numbers under a fresh badge', () async {
      final panel = await _outageAndRecovery();

      final early = panel.events
          .where((e) => !e.stale && !e.allPagesCurrent)
          .toList();
      expect(early, isEmpty,
          reason: 'viewFreshness emitted false ${early.length} time(s) while '
              'pages were still holding pre-outage values '
              '(${early.map((e) => e.pagesStillOld).join(", ")} page(s) old at '
              'the moment of the event). The badge said the view was fresh '
              'while the screen showed numbers from before the outage — which '
              'is the whole of the core value, inverted.');
    });

    test('and it does become fresh, once every page holds its snapshot',
        () async {
      // **The load-bearing companion.** Without this arm the one above passes
      // on a client whose badge never clears at all, which is a worse product
      // than the bug. 14-13 is the plan that learned this.
      final panel = await _outageAndRecovery();

      expect(panel.watchdog.viewIsStale, isFalse,
          reason: 'the view is fresh once every page is holding data from the '
              'current connection');
      final cleared = panel.events.where((e) => !e.stale).toList();
      expect(cleared, hasLength(1),
          reason: 'exactly one `false` for one recovery: '
              '${panel.events.map((e) => e.stale).toList()}');
      expect(cleared.single.allPagesCurrent, isTrue,
          reason: 'and it was emitted with every page already current');
    });
  });

  group('the link deadline is a different signal and still gets fed', () {
    test('a resync longer than the freshness deadline is not torn down',
        () async {
      final gateway = await _ResyncGateway.start();
      // Each page's snapshot takes most of the deadline; two pages, answered
      // one after the other, take more than all of it. That is the ordinary
      // shape of a multi-page panel on a congested link, and the half-open
      // detector must not read it as a dead socket.
      gateway.subscribeDelay = const Duration(milliseconds: 450);

      final started = DateTime.now();
      final panel = await _panelOn(gateway);
      final elapsed = DateTime.now().difference(started);

      // Anti-vacuity, and not decoration: if a later edit lowers the delay or
      // raises the deadline, this arm silently stops being about anything.
      expect(elapsed, greaterThan(_freshness),
          reason: 'the resync took ${elapsed.inMilliseconds} ms against a '
              '${_freshness.inMilliseconds} ms freshness deadline — it has to '
              'outlast the deadline for this arm to be about the half-open '
              'detector at all');
      expect(gateway.hellos, 1,
          reason: 'the panel handshook ${gateway.hellos} times to establish '
              'two pages. A second handshake means the half-open detector tore '
              'down the connection that was succeeding — and since '
              '`backoff.reset()` is reachable only from `_enter(ready)`, that '
              'loop is self-sustaining');
      expect(
          _pages.every((page) => panel.subscriptions[page]!.lastSeq != null),
          isTrue);
      expect(panel.events.where((e) => e.stale), isEmpty,
          reason: 'and the badge never went stale during a resync that was '
              'slow but alive');

      // ## The live control, without which this arm asserts nothing
      //
      // Everything above is a statement that something did **not** happen, and
      // the detector being *disarmed* satisfies all of it. That is not
      // hypothetical: `_deadline` is armed in exactly one place — inside
      // `sawFrame` — and it starts null, so a client that fed it from nowhere
      // would sail through every expectation above while having no half-open
      // detector at all. Sabotage (f) did precisely that and this arm was green
      // for it.
      //
      // So: go silent and prove the deadline was armed and running the whole
      // time by watching it fire. A detector that can still kill a genuinely
      // quiet link is one that was alive to be *not* fired during the resync.
      gateway.subscribeDelay = Duration.zero;
      await _until(
          'the half-open detector to fire once the link really does go quiet',
          () => panel.watchdog.viewIsStale);
      expect(panel.events.where((e) => e.stale), hasLength(1),
          reason: 'the link deadline was never armed during the resync, so '
              '"the connection was not torn down" above was a statement about '
              'a detector that was not running. `sawFrame` is what arms it and '
              'the hello and subscribe responses are what feed it');
    });
  });

  group('the badge stays link-level', () {
    test('a subscription that is individually stale does not make the view '
        'stale', () async {
      // The `latency_gate_test.dart:146-161` property, restated where a fix
      // could break it. The two verdicts are deliberately independent: the
      // per-subscription set can be non-empty while the link is provably
      // healthy. A fix that coupled the badge to store contents — the tempting
      // shortcut, since "is the data current" is what the badge is *about* —
      // would turn every slow-moving tag into a stale panel.
      final gateway = await _ResyncGateway.start();
      final panel = await _panelOn(gateway);
      panel.events.clear();

      // Ticks that keep arriving — so the link is provably answering — but
      // which say every page was last evaluated ten minutes ago.
      final ticking = Timer.periodic(const Duration(milliseconds: 50),
          (_) => gateway.tick(staleBy: const Duration(minutes: 10)));
      addTearDown(ticking.cancel);

      await _until(
          'the per-subscription verdict to go stale',
          () => _pages.every(panel.watchdog.isSubscriptionStale));
      await Future<void>.delayed(_settle);
      ticking.cancel();

      expect(panel.watchdog.staleSubscriptions, hasLength(_pages.length),
          reason: 'anti-vacuity: both pages really are stale by the '
              'per-subscription verdict');
      expect(panel.watchdog.viewIsStale, isFalse,
          reason: 'the link answered a tick every 50 ms throughout. A grey '
              'panel here tells the operator the screen is dead when it is '
              'the plant that is quiet');
      expect(panel.events.where((e) => e.stale), isEmpty,
          reason: 'and no `true` was emitted on the link-level stream: '
              '${panel.events.map((e) => e.stale).toList()}');
    });
  });
}
