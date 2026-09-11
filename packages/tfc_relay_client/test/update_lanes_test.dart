@TestOn('vm')

/// Three lanes the gateway stages carefully and the client decoded and threw
/// away.
///
/// Source: 16-10, finding S4 (WSH-04), verified at source before a line was
/// written.
///
/// `UpdateParams` (`messages.dart:355-416`) carries five things a `u` frame can
/// say. The client's `_update` read exactly one of them:
///
/// * **`c` — changes.** Read, applied, pinned by half this suite.
/// * **`q` — quality-only transitions.** Decoded into `update.qualities` and
///   never looked at. A frame saying "handle 5 is now `badCommFault`, the
///   number is the one you already have" applied an *empty* change set,
///   advanced the sequence cleanly, and the transition evaporated. The widget
///   kept the old number under `Quality.good` — no gap, no complaint, and no
///   resync to heal it, because from the sequence's point of view nothing went
///   wrong. A comm fault on the line is the one thing this product exists to
///   put on the screen, and it was the one thing that could not get there.
/// * **`r` — removals.** Same: decoded into `update.removed`, never read. The
///   handle's last value survived as good forever.
/// * **`t` — the batch timestamp.** Its own doc says it applies "to values
///   without their own", and slim pushes are *defined* by omitting per-value
///   timestamps. Dropping it meant every slim push landed with
///   `sourceTime: null` — so value-age staleness stopped being computable at
///   the panel, which is the exact failure `WireValue.toDynamicValue`'s doc
///   says the type exists to prevent.
///
/// There is no comment anywhere in the client recording a decision to drop
/// them. That is the review's through-line: the layers are pinned, the defect
/// is in the seam between them.
///
/// ## Is this reachable from a real gateway? No — and that took a second look
///
/// 16-CONTEXT recorded S4 as "less latent than the review recorded", on the
/// grounds that `SendBuffer.putQuality` / `.remove` have a live production
/// caller at `tick_engine.dart:534/:537`, inside `_defer`. That is true and it
/// is not enough, because it stops one level short: **`_defer`'s inputs are
/// `pending.qualities` and `pending.removed`, which come out of
/// `buffer.drain()` — i.e. out of the same two lanes it is putting them back
/// into.** It is a closed loop with no entrance.
///
/// The origin-side filler is `session_handlers.dart:241`, and it calls
/// `putValue`, which *deletes* from both other lanes on the way past
/// (`send_buffer.dart:124-126`: "the value carries its own quality"). So
/// nothing in the shipping gateway ever puts the first `q` or `r` entry into a
/// buffer, `_defer` can only recirculate entries that are already there, and no
/// `_defer` can therefore ever put one on the wire.
///
/// **S4 is latent, then, not live** — and the client half is still wrong, which
/// is why this file exists rather than a deferral note. The wire contract
/// declares the lanes, the encoder emits them (`frame_encoder.dart:94-105`),
/// the buffer conflates them with real care (`putQuality` composes rather than
/// replaces a `badNonFinite` band, and says why), and the server suite tests
/// them. Every layer treats them as real except the one that has to render
/// them. The day a source grows a quality-only transition — an OPC UA session
/// dropping while the last reading stands, which is the ordinary shape of a
/// comm fault — the gateway will emit it correctly and the panel will show the
/// old number in green.
///
/// **So the frames here are hand-built and pushed by a scripted gateway.** Not
/// a weakness of the reproduction but a statement of its subject: the claim is
/// about what a *conforming peer's* frame does to this client, and a peer that
/// cannot yet be made to send one has to be scripted. The frames are built
/// through the protocol package's own encoders, so what arrives is the shape
/// `UpdateParams.toJson` produces and not a shape somebody guessed.
///
/// What breaks in the plant without this file: the freezer line loses its OPC
/// UA session, the gateway says so on the lane built to say it, and every panel
/// in the factory keeps showing the last temperature under a good-quality badge
/// until somebody walks to the freezer.
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

/// The key these arms watch, and the handle the gateway below mints for it.
const String _pageKey = 'ST101.CN01.MOT01.temperature';
const int _pageHandle = 1;

/// A second key, so an arm can prove a lane touched the handle it named and
/// left its neighbour alone.
const String _otherKey = 'ST101.CN01.MOT01.setpoint';
const int _otherHandle = 2;

/// A handle no subscribe answer ever announced. Arm 5's stranger.
const int _strangerHandle = 99;

const String _page = 'p';

/// The sequence the scripted snapshot answers with — four rather than zero, so
/// a comparison that read a fresh page as "nothing applied yet" cannot pass.
const int _snapshotSeq = 4;

/// The value the snapshot seeds, and the number every arm below expects to
/// still be there afterwards unless it changed it on purpose.
const int _seededValue = 1200;

const Duration _budget = Duration(seconds: 10);
const Duration _settle = Duration(milliseconds: 300);

/// The damper's window, short enough that arm 5 can outlive it inside [_budget].
const Duration _freshness = Duration(milliseconds: 400);

ClientConfig _lanesConfig() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      snapshotDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: _freshness,
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
    );

// ---------------------------------------------------------------------------
// The gateway.
// ---------------------------------------------------------------------------

/// A gateway that answers `hello` and `subscribe` by script and can push a `u`
/// frame naming any of the three lanes.
///
/// `_StormGateway`'s sibling (`update_storm_test.dart:154`), copied rather than
/// exported for the reason that file gives — a test private cannot be reached
/// across files — with one difference these arms need: [push] takes `q`, `r`
/// and a batch `t` as well as `c`, because those three are the subject.
///
/// Like its sibling, **the snapshot echoes the last sequence pushed**. A rebuild
/// mid-arm otherwise answers with a sequence behind the frames already sent, and
/// the gap recovers through `ResyncEngine.onUpdate`'s own path — which is not
/// the detector arm 5 is counting.
final class _LaneGateway {
  _LaneGateway._(this._http);

  static Future<_LaneGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _LaneGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many `subscribe` calls this gateway has answered. One per
  /// establishment, so arm 5's rebuild count is `subscribes - 1`.
  int subscribes = 0;

  /// The sequence of the last `u` frame pushed — what the next snapshot echoes.
  int lastPushedSeq = _snapshotSeq;

  /// Constant across an arm: nothing here is testing the generation gate, and a
  /// moving generation would make a frame's fate ambiguous between two rules.
  static const int generation = 7;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
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
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('lane-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': lastPushedSeq,
                  'generation': generation,
                  'handles': {_pageKey: _pageHandle, _otherKey: _otherHandle},
                  'snapshot': {
                    '$_pageHandle': WireValue.of(_seededValue).toJson(),
                    '$_otherHandle': WireValue.of(_seededValue).toJson(),
                  },
                },
              });
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

  /// Pushes a `u` frame naming whichever lanes an arm asks for.
  ///
  /// Built through `UpdateParams.toJson` rather than by hand, so an arm asserts
  /// against the shape the protocol package produces — including its omissions
  /// (`c`, `q` and `r` are all absent from the wire when empty) — and not
  /// against one this file invented.
  void push(
    int seq, {
    Map<int, WireValue> changes = const {},
    Map<int, Quality> qualities = const {},
    List<int> removed = const [],
    required int batchT,
  }) {
    lastPushedSeq = seq;
    _send({
      'jsonrpc': '2.0',
      'method': Methods.update,
      'params': UpdateParams(
        sub: _page,
        seq: seq,
        t: batchT,
        generation: generation,
        changes: changes,
        qualities: qualities,
        removed: removed,
      ).toJson(),
    });
  }

  /// A tick naming [seq], which is what keeps the link deadline fed while an
  /// arm sits still.
  void tick(int seq) => _send({
        'jsonrpc': '2.0',
        'method': Methods.tick,
        'params': {
          'serverTime': DateTime.now().millisecondsSinceEpoch,
          'subs': {
            _page: {
              'seq': seq,
              'evaluatedAt': DateTime.now().millisecondsSinceEpoch,
            },
          },
        },
      });

  void _send(Object? frame) {
    final socket = _link;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    await _link?.close().catchError((Object _) => null);
    await _http.close(force: true);
  }
}

typedef _Panel = ({
  ConnectionSupervisor supervisor,
  Map<String, SubscriptionState> subscriptions,
  ValueStore store,
});

/// Builds a supervisor holding one page, pointed at [gateway], and starts it.
Future<_Panel> _connected(_LaneGateway gateway) async {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_pageKey, _otherKey}),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: _lanesConfig(),
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(seconds: 2),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog: FreshnessWatchdog(
        config: _lanesConfig(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  await _until('the page to be established',
      () => subscriptions[_page]!.lastSeq == _snapshotSeq);
  return (
    supervisor: supervisor,
    subscriptions: subscriptions,
    store: store,
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

/// A timestamp that is unmistakably chosen rather than "about now".
///
/// Never `DateTime.now()`: an arm asserting that a *particular* number crossed
/// the seam cannot be written against a clock, and the house rule forbids it
/// anyway. These are real epoch milliseconds (2021-01-01 and 2021-01-02 UTC) so
/// they survive `WireValue`'s representable-range check.
const int _batchStamp = 1609459200000;
const int _valueStamp = 1609545600000;

DateTime _utc(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

void main() {
  group('the quality lane', () {
    test('a quality-only frame changes the quality and leaves the value alone',
        () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final node = panel.store.node(_pageKey);
      expect(node.value.value, _seededValue,
          reason: 'anti-vacuity: the snapshot must have seeded a good value, '
              'or "the value did not change" below asserts nothing');
      expect(node.value.quality, Quality.good);

      // The frame the gateway builds when an OPC UA session drops while the
      // last reading stands: no new number, a new quality. `c` is absent from
      // the wire entirely — `UpdateParams.toJson` omits an empty lane.
      gateway.push(_snapshotSeq + 1,
          qualities: {_pageHandle: Quality.badCommFault}, batchT: _batchStamp);

      await _until('the quality transition to land',
          () => node.value.quality == Quality.badCommFault);
      expect(node.value.value, _seededValue,
          reason: 'a quality-only transition is by definition not news about '
              'the value; inventing one here would put a null in a box that '
              'has a reading');
      expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq + 1,
          reason: 'the sequence advances cleanly — a quality-only frame is a '
              'frame, not a gap');
    });

    test('it touches the handle it named and nothing else', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final other = panel.store.node(_otherKey);

      gateway.push(_snapshotSeq + 1,
          qualities: {_pageHandle: Quality.badCommFault}, batchT: _batchStamp);
      await _until(
          'the quality transition to land',
          () =>
              panel.store.node(_pageKey).value.quality == Quality.badCommFault);

      expect(other.value.quality, Quality.good,
          reason: 'the neighbour was not named and must not be collateral');
      expect(other.value.value, _seededValue);
    });
  });

  group('the removal lane', () {
    // ## The semantics this arm pins, and why this one rather than the other
    //
    // The choice is between "the key is simply gone from the store" and "the
    // key reads as affirmatively unavailable", and they are different promises
    // to a widget. This picks the second: the node stays, its value becomes
    // null under [Quality.errorConfig].
    //
    // **Because the store already specifies it.** `value_store.dart:28-41`
    // distinguishes the two states in as many words — a key that has not
    // arrived yet is `uncertainNotYetKnown`, and "a key the source has
    // affirmatively been told is gone is a different fact, and carries
    // [Quality.errorConfig]". A `r` entry is the gateway making exactly that
    // affirmative statement, so the store's own rule decides this and no new
    // one is needed.
    //
    // **And because removing the node would orphan its listeners.** A
    // `ValueStoreNode` is handed to widgets as a `ValueListenable` and Phase
    // 4's builder listens to it directly, with no adapter object per key.
    // Dropping the node from the map does not detach anybody: the widget keeps
    // its reference to the dead node, `node(key)` mints a *new* one for the
    // next arrival, and the mimic is frozen on its last reading with no path
    // back — silently, forever, on a healthy link. That is a worse version of
    // the bug being fixed, arrived at while fixing it.
    test('a removed handle stops being served as a good value', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final node = panel.store.node(_pageKey);
      expect(node.value.quality.isGood, isTrue,
          reason: 'anti-vacuity: it has to be good before "stops being good" '
              'means anything');

      gateway.push(_snapshotSeq + 1,
          removed: [_pageHandle], batchT: _batchStamp);

      await _until('the removal to land', () => !node.value.quality.isGood);
      expect(node.value.quality, Quality.errorConfig,
          reason: 'affirmatively gone, which is not the same fact as '
              'uncertainNotYetKnown — see the comment above this group');
      expect(node.value.value, isNull,
          reason: 'a value under errorConfig is a number nobody stands behind');
      expect(panel.store.node(_otherKey).value.quality, Quality.good,
          reason: 'the neighbour was not named');
    });
  });

  group('the batch timestamp', () {
    test('is the source time for a value that carries none', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final node = panel.store.node(_pageKey);

      // A slim push: `WireValue.of` with no `t`, which is what
      // `session_handlers.dart` produces for a value whose source stamped none,
      // and what `toJson` omits from the wire.
      gateway.push(_snapshotSeq + 1,
          changes: {_pageHandle: WireValue.of(1300)}, batchT: _batchStamp);

      await _until('the value to land', () => node.value.value == 1300);
      expect(node.value.sourceTime, _utc(_batchStamp),
          reason: 'without this, value-age staleness is uncomputable at the '
              'panel — the exact failure WireValue.toDynamicValue says the '
              'type exists to prevent');
    });

    test('never overrides a value that carries its own', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final node = panel.store.node(_pageKey);

      gateway.push(_snapshotSeq + 1,
          changes: {_pageHandle: WireValue.of(1400, t: _valueStamp)},
          batchT: _batchStamp);

      await _until('the value to land', () => node.value.value == 1400);
      expect(node.value.sourceTime, _utc(_valueStamp),
          reason: 'messages.dart:373 says the batch stamp applies "to values '
              'without their own" — it is a fallback, and a fallback that '
              'overrides is a hostile batch stamp rewriting honest ones');
      expect(node.value.sourceTime, isNot(_utc(_batchStamp)));
    });
  });

  group('the new lanes are not a way around the rebuild budget', () {
    test('a stranger in the quality lane is detected, and damped like one in '
        'the change lane', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final establishments = gateway.subscribes;
      expect(establishments, 1, reason: 'one subscribe to get here');

      // A storm naming a handle this session never announced — in `q` only, so
      // the change lane cannot be the thing that noticed. Sixty frames over a
      // window several times the damper's, at the cadence a busy page pushes.
      final started = DateTime.now();
      for (var i = 1; i <= 60; i++) {
        gateway.push(_snapshotSeq + i,
            qualities: {_strangerHandle: Quality.badCommFault},
            batchT: _batchStamp);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await Future<void>.delayed(_settle);
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      final rebuilds = gateway.subscribes - establishments;

      // **Both halves, and the arm is worthless without either.** The floor is
      // what fails today, when the lane is not read at all and a stranger in it
      // costs nothing because nothing looked. The ceiling is what fails if the
      // lane is wired to its own detector instead of through
      // `_mayRebuild` — 16-07's budget is one rebuild per subscription per
      // freshnessDeadline whichever detector asked, and a second door into
      // `onResync` reintroduces S14 by the back way.
      expect(rebuilds, greaterThan(0),
          reason: 'a stranger in the quality lane must be seen at all: this is '
              'the half that fails while the lane is discarded');
      final budget = (elapsedMs / _freshness.inMilliseconds).ceil() + 2;
      expect(rebuilds, lessThanOrEqualTo(budget),
          reason: '$rebuilds rebuilds over $elapsedMs ms is more than one per '
              '${_freshness.inMilliseconds} ms — the new lane bypassed '
              "16-07's shared damper");
      expect(panel.supervisor.resync.complaints.join('\n'), contains('$_strangerHandle'),
          reason: 'the complaint names the handle, exactly as the change lane '
              'does');
    });

    test('a stranger in the removal lane is detected and damped too', () async {
      final gateway = await _LaneGateway.start();
      final panel = await _connected(gateway);
      final establishments = gateway.subscribes;

      final started = DateTime.now();
      for (var i = 1; i <= 60; i++) {
        gateway.push(_snapshotSeq + i,
            removed: [_strangerHandle], batchT: _batchStamp);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await Future<void>.delayed(_settle);
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      final rebuilds = gateway.subscribes - establishments;

      expect(rebuilds, greaterThan(0),
          reason: 'the removal lane is the second door and needs its own arm: '
              'a fix that wired `q` and forgot `r` passes the arm above');
      final budget = (elapsedMs / _freshness.inMilliseconds).ceil() + 2;
      expect(rebuilds, lessThanOrEqualTo(budget),
          reason: '$rebuilds rebuilds over $elapsedMs ms — the removal lane '
              "bypassed 16-07's shared damper");
      expect(panel.supervisor.resync.complaints.join('\n'), contains('$_strangerHandle'));
    });
  });
}
