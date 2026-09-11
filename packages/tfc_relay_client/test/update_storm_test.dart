@TestOn('vm')

/// One rebuild budget, one honest complaint, one bounded list.
///
/// Source: 16-07, findings S14 and IN-02.
///
/// **The storm.** 07-REVIEW WR-02 rate-limited the *tick* detector to one
/// rebuild per subscription per [ClientConfig.freshnessDeadline], because "the
/// F9/G3 resync-storm hazard reached through this detector". The detector
/// beside it — `_update`'s unannounced-handle branch — reaches the same
/// `ResyncEngine.onResync` with no rate limit and no damper at all. A gateway
/// pushing at 10–20 Hz with a handle this session never announced in every
/// frame is therefore several full ~1500-key snapshot requests per second,
/// against the one process serving every screen in the plant, for as long as
/// the misconfiguration lasts. `resync_test.dart`'s
/// `a gateway whose advertised sequence never comes down is damped` is the
/// same property on the other detector; these arms are that one aimed here.
///
/// **And two dampers are not one budget.** A rebuild is a rebuild whichever
/// detector asked for it. Giving each detector its own limit means the page
/// rebuilds at twice the rate WR-02 decided on, which is why arm 2 exists
/// beside arm 1 and drives *both* detectors on the same subscription: arm 1
/// says "damped", arm 2 says "damped *together*", and a fix that only does the
/// first passes one of them.
///
/// **A frame that is about to be discarded costs nothing.** The generation gate
/// lives inside `ResyncEngine.onUpdate`, i.e. *after* the handle-resolution
/// loop has already filed its complaints and *before* the rebuild trigger below
/// it. So a frame from an establishment this client has already replaced — the
/// ordinary shape of recovery, and the shape a hostile peer can manufacture at
/// will — both grew the operator-facing list and forced a full page rebuild,
/// for a frame nothing was ever going to apply.
///
/// **The list is bounded, and says so.** `complaints` is the one list an
/// operator reads, and it was the only diagnostic list in this package that was
/// never bounded — `_waits`, `_writeStatusQueries` and `_writeStatusAnswers`
/// were all capped citing 04-REVIEW IN-02, *"a leak with a diagnostic excuse"*.
/// One mistyped key on a flapping link is a couple of entries a minute all
/// shift; under the storm above it is unbounded. Bounded at 256 rather than the
/// 64 the debug histories use, because 64 entries is a shift's worth of
/// nothing — and the truncation is **visible**, because a list that silently
/// drops the line explaining an incident is a worse lie than a long one.
///
/// What breaks in the plant without this file: one page with a stale key list
/// takes the gateway down for every other panel in the factory, and the
/// complaint list that would have named the key has already rolled past it.
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

// ---------------------------------------------------------------------------
// The page these arms drive.
// ---------------------------------------------------------------------------

/// The one key the gateway below announces.
const String _pageKey = 'ST101.CN01.MOT01.setpoint';

/// The handle it announces it under.
const int _pageHandle = 1;

/// A handle this session never announces. Every arm's storm is built on it.
const int _stranger = 99;

/// The subscription name.
const String _page = 'p';

/// The sequence the first snapshot answers with.
///
/// Four rather than zero for `resync_test.dart:118-123`'s reason: a comparison
/// written against a constant, or one that read a fresh page as "nothing
/// applied yet", would pass every arm below if the baseline were zero.
const int _snapshotSeq = 4;

/// The generation this gateway mints, and never changes.
///
/// Deliberately constant across re-establishes, which the real registry's is
/// not. These arms are about the *rebuild budget*, and a generation that moved
/// under them would mean a storm frame raced a rebuild into the generation gate
/// and was dropped for a reason no arm here is about. Arm 3 is the one case
/// that wants a mismatch, and it asks for one explicitly.
const int _generation = 7;

/// The rebuild budget's window. One rebuild per subscription per this.
///
/// Also the link deadline: `FreshnessWatchdog` tears a socket down after this
/// long with no frame of any kind. Every arm below either keeps frames flowing
/// or asserts well inside it.
const Duration _freshness = Duration(milliseconds: 400);

/// How long between frames in the storms. Roughly the plant's fan-out cadence.
const Duration _framePeriod = Duration(milliseconds: 30);

/// How many frames each storm pushes.
const int _stormFrames = 60;

/// How long an arm waits for a rebuild it expects, and how long it watches to
/// be sure nothing further happened. Both well inside [_freshness].
const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 120);

/// The cap the complaints list is bounded at.
///
/// Hard-coded rather than read from the production constant on purpose: this
/// file was written before the constant existed, and a pin that imports the
/// number it is pinning agrees with any value the code picks.
const int _complaintCap = 256;

/// How many complaints arm 4 drives, comfortably past the cap.
const int _flood = 300;

/// The first handle of arm 4's flood. Numbered so the newest are the largest.
const int _floodBase = 1000;

ClientConfig _stormConfig() => ClientConfig(
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

/// A gateway that answers `hello` and `subscribe` by script and pushes whatever
/// an arm asks it to.
///
/// The same instrument as `resync_test.dart`'s `_SequencedGateway`, copied
/// rather than exported (a test private cannot be reached across files) with
/// two differences, both of which these arms need:
///
/// * **its snapshot answers with the sequence it last pushed.** A rebuild reads
///   the baseline back to whatever the snapshot carries, so a gateway answering
///   a constant would turn the arm's *next* frame into a sequence gap — and a
///   gap recovers through `ResyncEngine.onUpdate`'s own path, which is not the
///   detector any of these arms is counting. Echoing the last pushed sequence
///   makes every storm frame an in-sequence one, so the only rebuilds counted
///   are the ones a detector asked for.
/// * **its generation is a constant.** See [_generation].
final class _StormGateway {
  _StormGateway._(this._http);

  static Future<_StormGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _StormGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many `subscribe` calls this gateway has answered. Every arm's number.
  int subscribes = 0;

  /// The sequence of the last `u` frame pushed — what the next snapshot echoes.
  int lastPushedSeq = _snapshotSeq;

  /// The value the next snapshot carries.
  Object? snapshotValue = 1200;

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
                  server: const PeerInfo('storm-gateway', '0.0.1'),
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
                  'generation': _generation,
                  'handles': {_pageKey: _pageHandle},
                  'snapshot': {
                    '$_pageHandle': WireValue.of(snapshotValue).toJson(),
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

  /// Pushes an update naming [handles] at [seq], under [generation].
  void update(int seq, Map<int, Object?> handles, {int? generation}) {
    lastPushedSeq = seq;
    _send({
      'jsonrpc': '2.0',
      'method': Methods.update,
      'params': {
        'sub': _page,
        'seq': seq,
        't': DateTime.now().millisecondsSinceEpoch,
        'g': generation ?? _generation,
        'c': {
          for (final entry in handles.entries)
            '${entry.key}': WireValue.of(entry.value).toJson(),
        },
      },
    });
  }

  /// Announces a tick naming [seq] for the page.
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

/// Everything an arm drives.
typedef _Panel = ({
  ConnectionSupervisor supervisor,
  Map<String, SubscriptionState> subscriptions,
  ValueStore store,
});

/// Builds a supervisor holding one page, pointed at [gateway], and starts it.
Future<_Panel> _connected(_StormGateway gateway) async {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_pageKey}),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: _stormConfig(),
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(seconds: 2),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog: FreshnessWatchdog(
        config: _stormConfig(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  await _until('the page to be established',
      () => subscriptions[_page]!.lastSeq == _snapshotSeq);
  return (supervisor: supervisor, subscriptions: subscriptions, store: store);
}

/// Polls [done] until it holds or [_budget] runs out, naming [what] on failure.
Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// How many rebuilds a window of [elapsedMs] is allowed to cost.
///
/// One per [_freshness], plus one for the first — plus one more slot of slack,
/// because the window is measured by a `Future.delayed` loop on a machine that
/// is also running a gateway, and a bound that failed when the loop ran a
/// millisecond long would be a bound about the test runner. The number that
/// matters is the *shape*: it is proportional to the window and not to the
/// frame count, so an undamped detector is off by the frame rate and cannot
/// hide inside the slack.
int _allowedRebuilds(int elapsedMs) =>
    (elapsedMs / _freshness.inMilliseconds).ceil() + 2;

void main() {
  group('the two detectors share one rebuild budget', () {
    test('a gateway naming an unannounced handle in every frame does not '
        'rebuild the page once per frame', () async {
      final gateway = await _StormGateway.start();
      final panel = await _connected(gateway);
      expect(gateway.subscribes, 1,
          reason: 'the page was established by more than one subscribe, so '
              'the count below starts from a number this arm did not set');

      final window = Stopwatch()..start();
      var seq = _snapshotSeq;
      for (var i = 0; i < _stormFrames; i++) {
        gateway.update(++seq, {_pageHandle: 1200 + i, _stranger: 'nobody'});
        await Future<void>.delayed(_framePeriod);
      }
      await Future<void>.delayed(_settle);
      window.stop();

      final rebuilds = gateway.subscribes - 1;
      final allowed = _allowedRebuilds(window.elapsedMilliseconds);
      expect(rebuilds, lessThanOrEqualTo(allowed),
          reason: '$_stormFrames frames over ${window.elapsedMilliseconds} ms, '
              'every one of them naming one handle this session never '
              'announced, cost $rebuilds full page rebuilds. The budget for '
              'that window is $allowed — one per subscription per '
              '${_freshness.inMilliseconds} ms, which is the bound 07-REVIEW '
              'WR-02 set on the detector beside this one. A count that tracks '
              'the frame rate instead is several ~1500-key snapshot requests '
              'per second against the one gateway serving the plant, for as '
              'long as the misconfiguration lasts');
      expect(rebuilds, greaterThan(0),
          reason: 'anti-vacuity: the storm has to have cost at least one '
              'rebuild, or the bound above is a statement about a detector '
              'that never fired and every mutation of it stays green');
      expect(panel.subscriptions[_page]!.lastSeq, greaterThan(_snapshotSeq),
          reason: 'anti-vacuity: the storm frames have to have been applied. '
              'A page that dropped all of them never reached the detector '
              'this arm is counting');
    });

    test('one budget, not one per detector: a page driven by both detectors '
        'still rebuilds at one detector\'s rate', () async {
      // The whole point of arm 2 beside arm 1. Two detectors that each honour
      // "one rebuild per subscription per freshnessDeadline" are not that
      // bound: the page rebuilds twice as often as either of them allows, and
      // the gateway carries twice the snapshot load WR-02 decided on.
      final gateway = await _StormGateway.start();
      final panel = await _connected(gateway);
      expect(gateway.subscribes, 1,
          reason: 'the page was established by more than one subscribe, so '
              'the count below starts from a number this arm did not set');

      final window = Stopwatch()..start();
      var seq = _snapshotSeq;
      for (var i = 0; i < _stormFrames ~/ 2; i++) {
        // The update detector: a handle nobody announced.
        gateway.update(++seq, {_pageHandle: 1200 + i, _stranger: 'nobody'});
        await Future<void>.delayed(_framePeriod);
        // The tick detector: a sequence the gateway's own subscribe answer
        // will not come up to, so the mismatch survives every rebuild.
        gateway.tick(seq + 5);
        await Future<void>.delayed(_framePeriod);
      }
      await Future<void>.delayed(_settle);
      window.stop();

      final rebuilds = gateway.subscribes - 1;
      final allowed = _allowedRebuilds(window.elapsedMilliseconds);
      expect(rebuilds, lessThanOrEqualTo(allowed),
          reason: 'a page driven by both detectors at once cost $rebuilds '
              'rebuilds over ${window.elapsedMilliseconds} ms, against a '
              'budget of $allowed. A rebuild is a rebuild whichever detector '
              'asked for it, so the two have to consult one damper: two '
              'detectors each honouring their own copy of the limit is twice '
              'the limit');
      expect(rebuilds, greaterThan(0),
          reason: 'anti-vacuity: neither detector fired, so this arm is a '
              'statement about nothing');

      final damping = panel.supervisor.resync.complaints
          .where((line) => line.contains('suppressed'))
          .toList();
      expect(damping, isNotEmpty,
          reason: 'the client rebuilt a page and then declined to keep '
              'rebuilding it, and said nothing on the one surface an operator '
              'reads: ${panel.supervisor.resync.complaints}. Silence sends '
              'whoever is debugging this to the wrong end of the link');
    });
  });

  group('a frame the generation gate will discard costs nothing', () {
    test('a stale-generation frame naming an unannounced handle adds no '
        'complaint and forces no rebuild', () async {
      final gateway = await _StormGateway.start();
      final panel = await _connected(gateway);
      expect(panel.supervisor.resync.complaints, isEmpty,
          reason: 'the page established with complaints already on the list, '
              'so "no complaint was added" below would be about a number this '
              'arm did not set');

      // From an establishment this client has already replaced. `onUpdate`'s
      // generation gate drops it silently and does not touch the sequence —
      // but the handle-resolution loop and the rebuild trigger both run
      // *around* that gate, so the frame used to cost a complaint and a full
      // page rebuild on its way to being thrown away.
      gateway.update(_snapshotSeq + 1, {_pageHandle: 1300, _stranger: 'ghost'},
          generation: _generation - 1);
      await Future<void>.delayed(_settle);

      expect(panel.supervisor.resync.complaints, isEmpty,
          reason: 'a frame nothing was ever going to apply grew the '
              'operator-facing list: ${panel.supervisor.resync.complaints}. A '
              'frame crossing a re-establish is the ordinary shape of '
              'recovery, which is exactly why `onUpdate` drops it without a '
              'complaint of its own — and why the loop above it must not file '
              'one either');
      expect(gateway.subscribes, 1,
          reason: 'a discarded frame cost ${gateway.subscribes - 1} full page '
              'rebuilds. That is a rebuild storm a peer can drive at will by '
              'replaying frames from a generation this client has already '
              'retired');
      expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq,
          reason: 'the gate is supposed to leave the sequence alone; if it '
              'moved, this arm is measuring a frame that was applied');

      // The positive half, and it is load-bearing: "nothing happened" is
      // equally consistent with a frame that never reached the handler at all.
      gateway.update(_snapshotSeq + 1, {_pageHandle: 1300, _stranger: 'ghost'});
      await _until('the rebuild a current-generation stranger asks for',
          () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      expect(
          panel.supervisor.resync.complaints
              .where((line) => line.contains('$_stranger'))
              .length,
          1,
          reason: 'the identical frame carrying the *current* generation has '
              'to cost exactly one complaint. If it does not, the arm above '
              'proved only that this gateway cannot reach the detector');
    });
  });

  group('the complaints list is bounded, and admits what it dropped', () {
    test('past the cap it keeps the newest and names the count it shed',
        () async {
      final gateway = await _StormGateway.start();
      final panel = await _connected(gateway);
      expect(panel.supervisor.resync.complaints, isEmpty,
          reason: 'the page established with complaints already on the list, '
              'so the arithmetic below would be about entries this arm did '
              'not drive');

      // One frame, one event, $_flood strangers in it — the shape a page with
      // a stale key list produces on its first frame after a gateway
      // reconfiguration.
      gateway.update(_snapshotSeq + 1, {
        _pageHandle: 1300,
        for (var i = 0; i < _flood; i++) _floodBase + i: 'stranger',
      });
      await _until('the rebuild the strangers ask for',
          () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      final complaints = panel.supervisor.resync.complaints;

      expect(complaints.length, lessThanOrEqualTo(_complaintCap),
          reason: '$_flood unannounced handles in one frame left '
              '${complaints.length} entries on a list nothing trims. '
              '`_waits`, `_writeStatusQueries` and `_writeStatusAnswers` were '
              'all bounded citing 04-REVIEW IN-02 — "a leak with a diagnostic '
              'excuse" — and this is the only one of the four an operator '
              'actually reads');
      expect(complaints.length, greaterThan(_complaintCap ~/ 2),
          reason: 'the list holds only ${complaints.length} entries out of a '
              'cap of $_complaintCap. This is the other direction of the same '
              'bound: a list that sheds almost everything satisfies "does not '
              'grow" vacuously, and 256 was chosen over the 64 the debug '
              'histories use precisely because a short operator-facing list is '
              'a shift\'s worth of nothing');

      expect(complaints.last, contains('${_floodBase + _flood - 1}'),
          reason: 'the newest complaint is the one that explains what is '
              'happening now, and it is not on the list: ${complaints.last}. A '
              'bound that sheds the tail keeps the history and throws away the '
              'incident');
      expect(complaints.any((line) => line.contains('$_floodBase ')), isFalse,
          reason: 'the oldest complaint survived a truncation that was '
              'supposed to shed it, so entries are not being dropped from the '
              'head and the cap is doing something other than what it says');

      final marker = complaints.first;
      expect(marker, contains('dropped'),
          reason: 'the head of a truncated list has to say it was truncated. '
              'It reads "$marker". A silently shortened operator-facing list '
              'is a worse lie than a long one: the line that explains the '
              'incident is gone and nothing says so');
      final counted = RegExp(r'\d+').firstMatch(marker);
      expect(counted, isNotNull,
          reason: 'the truncation marker "$marker" names no count, so it says '
              'that something was lost without saying how much');
      expect(int.parse(counted!.group(0)!), _flood - (complaints.length - 1),
          reason: 'the marker\'s count has to be the number actually shed: '
              '$_flood complaints arrived and ${complaints.length - 1} of them '
              'are still on the list beside the marker');
    });
  });
}
