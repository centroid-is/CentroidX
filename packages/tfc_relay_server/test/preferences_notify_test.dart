@TestOn('vm')

/// `preferences.changed`, over the wire it actually travels on.
///
/// The handler has existed on the client since 04-REVIEW WR-07 — registered
/// then precisely because *"a handler that does not exist is a different defect
/// from a feature that has not shipped, and only one of the two is fixed by
/// waiting"*. This file is the other half finally arriving, and it judges the
/// three things a sender gets wrong.
///
/// ## Coalescing is a deliverable, not a nicety
///
/// `peer.sendNotification` lands in `SessionSink.add`, which is
/// `buffer.putPriority` — a lane that is byte-capped at 8 MiB, entry-capped,
/// drained only by the tick and **not conflated** (`send_buffer.dart:185-196`).
/// A `clear()` over five hundred preference keys is therefore five hundred
/// frames per connected client, and the verdict at the end of that is a
/// `BufferDisconnect`, which `relay_session.dart:416-424` turns into
/// `close(4004)`. In plant terms: an engineer resets the settings on one
/// laptop and every panel in the fish factory drops its link, reporting
/// backpressure. So the sender buffers keys into a **set** and flushes once on
/// a microtask (T-10-19).
///
/// A microtask rather than a timer, copied from the shape
/// `served_state_man.dart:799-824` already uses: a burst applies
/// synchronously, so by the time the microtask queue drains, every key that
/// burst touched is pending and one frame carries all of them. A timer would
/// coalesce *across* bursts too, which would make the count this file asserts
/// depend on how fast the machine ran.
///
/// ## One listener per session, and each cancels its own
///
/// The gateway serves N sessions from **one shared source**
/// (`relay_server.dart:213-214`, "One instance, shared"), so each session
/// attaches its own listener to the one change stream. The tidier-looking
/// alternative — one server-level subscription fanning out to the registry —
/// is deliberately not what is built, and the reason is in this file: a
/// per-session listener is what makes the teardown arm mean anything, and the
/// fan-out shape would need a session registry of its own to replace what
/// `_teardown` already does for free.
///
/// ## How the counting is done without timing
///
/// Two of the cases below assert **exactly one** frame, which is a claim about
/// something that did *not* arrive. Rather than waiting a while and hoping,
/// they use the lane's own ordering: after the burst, the case makes an
/// ordinary round trip (`ping`) and waits for its answer. Answers and
/// notifications share the priority lane and it is FIFO, so by the time the
/// ping's answer is on the client, every notification queued before it is too.
/// The barrier is the protocol's, not the clock's.
///
/// The cross-client case is the one genuine wall-clock property here — a frame
/// has to cross a socket to a *different* session — so it uses `within` with a
/// deliberately generous budget. The budget is not a latency claim: what is
/// being judged is that the news arrives at all.
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

/// What a frame crossing a real socket to a second session is given.
///
/// Generous on purpose, and it is **not** a latency budget: the property is
/// that a second client hears the news at all, the tick is 50 ms, and this
/// suite runs on a machine that is often carrying every other agent's `dart`
/// process at once. A tight budget here would fail for the load rather than
/// for the property, which is the one thing a named budget must not do.
const _arrival = Duration(seconds: 5);

/// One gateway, one shared preference store, and as many panels as a case
/// wants.
final class _Plant {
  _Plant._(this.store, this.server);

  /// The store every session on this gateway is served from. Driveable
  /// directly, which is how a case plays "somebody else changed a setting".
  final FakePreferences store;
  final RelayServer server;

  static Future<_Plant> start({FakePreferences? preferences}) async {
    final store = preferences ?? FakePreferences();
    final plant = FakeStateMan(preferences: store);
    return _start(store, plant, plant);
  }

  /// A gateway whose source declares it has no preference store at all.
  static Future<_Plant> withoutPreferences() async {
    final plant = FakeStateMan();
    return _start(FakePreferences(), _NoPreferences(plant), plant);
  }

  static Future<_Plant> _start(
      FakePreferences store, StateManApi source, FakeStateMan owner) async {
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: source,
      config: fixtureConfig(),
      // Several cases here provoke refusals on purpose; a suite that printed a
      // trace per provoked refusal trains everyone to scroll past them.
      onError: (_, __, ___) {},
    );
    await server.start();
    addTearDown(() async {
      await server.close();
      await owner.dispose();
    });
    return _Plant._(store, server);
  }

  /// A connected panel, past the handshake unless [hello] says otherwise.
  Future<_Panel> panel({bool hello = true}) async {
    final opened = server.sessions.opened.first;
    final ws =
        IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await ws.ready;
    final panel = _Panel._(ws);
    final peer = rpc.Client(panel._tap(wsChannel(ws)));
    panel._peer = peer;
    unawaited(peer.listen().catchError((Object _) => null));
    addTearDown(() async {
      await peer.close();
      await ws.sink.close().catchError((Object _) {});
    });
    // Awaited before the handshake so a case reading `sessions` cannot race
    // the accept (`ws_harness.dart:315`'s argument).
    await opened.timeout(const Duration(seconds: 5));
    if (hello) await panel.hello();
    return panel;
  }
}

/// One connected client, and every frame it has been sent.
final class _Panel {
  _Panel._(this._ws);

  final WebSocketChannel _ws;
  late final rpc.Client _peer;

  /// Every frame this client received, raw and in order.
  final inbound = <String>[];

  /// The `preferences.changed` frames, decoded to their key lists.
  List<List<String>> get announcements => [
        for (final frame in inbound)
          if (_isChanged(frame))
            [
              for (final key
                  in ((jsonDecode(frame) as Map)['params'] as Map)['keys']
                      as List)
                '$key',
            ],
      ];

  static bool _isChanged(String frame) {
    final decoded = jsonDecode(frame);
    return decoded is Map &&
        decoded['method'] == DataServiceMethods.preferencesChanged;
  }

  StreamChannel<String> _tap(StreamChannel<String> base) => StreamChannel<String>(
      base.stream.map((frame) {
        inbound.add(frame);
        return frame;
      }),
      base.sink);

  Future<void> hello() => request(Methods.hello,
      params: helloParams(), what: 'the handshake over a real socket');

  Future<Object?> request(String method,
          {Object? params,
          String? what,
          Duration budget = const Duration(seconds: 5)}) =>
      within(_peer.sendRequest(method, params),
          what ?? 'a $method answer over a real socket',
          budget: budget);

  /// A round trip that carries no meaning of its own, used as an ordering
  /// barrier: answers and notifications share the priority lane, and it is
  /// FIFO, so anything queued before this answer is on the client by the time
  /// it lands.
  Future<void> barrier(String what) async =>
      request(Methods.ping, what: 'a ping as a barrier after $what');

  bool get isOpen => _ws.closeCode == null;
}

/// A source that has a plant but declares no preference store.
///
/// Written out member by member rather than with `noSuchMethod`, for
/// `PolicyStateMan`'s reason: a forwarder would absorb an interface member
/// added later and this class would stop being the narrow thing it is.
final class _NoPreferences implements StateManApi {
  _NoPreferences(this._source);

  final StateManApi _source;

  @override
  PreferencesApi get preferences =>
      throw UnsupportedError('this source has no preference store');

  @override
  List<String> get keys => _source.keys;

  @override
  ValueListenable<DynamicValue> listen(String key) => _source.listen(key);

  @override
  Stream<DynamicValue> subscribe(String key) => _source.subscribe(key);

  @override
  DynamicValue? read(String key) => _source.read(key);

  @override
  Future<DynamicValue> readFresh(String key) => _source.readFresh(key);

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      _source.readMany(keys);

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _source.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      _source.writeStatus(cmds);

  @override
  Future<HoldHandle> holdToRun(String key) => _source.holdToRun(key);

  @override
  BrowseApi get browse => _source.browse;

  @override
  TimeseriesApi get timeseries => _source.timeseries;

  @override
  HistoryViewApi get historyViews => _source.historyViews;

  // Delegated, because this double's whole point is that `preferences` is the
  // ONE thing it declares it has not got. A second local refusal would make it
  // a source with two absences and stop it being the narrow thing it is.
  @override
  AccessTemplateApi get accessTemplates => _source.accessTemplates;

  @override
  AccessAdminApi get accessAdmin => _source.accessAdmin;

  @override
  AuditApi get audit => _source.audit;

  @override
  BackendConfigApi get backendConfig => _source.backendConfig;

  @override
  Future<void> dispose() => _source.dispose();
}

void main() {
  group('one set is one frame naming one key', () {
    test('a panel hears its own write', () async {
      final plant = await _Plant.start();
      final panel = await plant.panel();

      await panel.request(DataServiceMethods.prefSetString,
          params: {'key': 'svn.site.name', 'value': 'Sæból'},
          what: 'saving a preference');
      await panel.barrier('the set');

      expect(panel.announcements, [
        ['svn.site.name'],
      ], reason: 'the session that made the change is told about it like any '
          'other: contract check 13 subscribes twice on **one** client and '
          'expects both listeners to hear the write that client just made, so '
          'a gateway that suppressed the echo would fail it');
    });

    test('a panel that never said hello is told nothing', () async {
      // The listener attaches when the session starts, because a change that
      // happens before anybody asked is still a change a settings page must
      // not miss. What must not happen is a frame reaching a peer the gateway
      // cannot name: preference keys are the gateway's own configuration
      // vocabulary, and announcing them to an unauthenticated socket is a
      // disclosure nothing else on this wire makes.
      final plant = await _Plant.start();
      final quiet = await plant.panel(hello: false);
      final helloed = await plant.panel();

      await plant.store.setString('key_mappings', '{"CN01":"x"}');
      await within(
          _untilAnnounced(helloed), 'the authenticated panel hearing the change',
          budget: _arrival);

      expect(quiet.announcements, isEmpty,
          reason: 'the authenticated panel next door heard this change, so the '
              'sender ran and the silence here is the gate rather than a '
              'notification that was never sent');
      expect(quiet.isOpen, isTrue,
          reason: 'dropped, not answered and not a close: a pre-hello session '
              'is a socket that has not authenticated yet, not a protocol '
              'violation');
    });
  });

  group('a burst is one frame, however many keys moved', () {
    test('a five-hundred-key clear crosses as one frame naming five hundred',
        () async {
      final plant = await _Plant.start();
      // Seeded **before** the panel connects, so the seeding burst is not part
      // of what is counted: the session's listener does not exist yet.
      for (var i = 0; i < 500; i++) {
        await plant.store.setInt('svn.page.$i', i);
      }
      final panel = await plant.panel();

      final sourceEvents = <String>[];
      final tap = plant.store.onPreferencesChanged.listen(sourceEvents.add);
      addTearDown(tap.cancel);

      await plant.store.clear();
      await panel.barrier('a five-hundred-key clear');

      expect(sourceEvents, hasLength(500),
          reason: 'the anti-vacuity arm, and it goes first: the store fires '
              'once per key removed, so "one frame" below is this gateway '
              'coalescing rather than a store that announced the clear as a '
              'single event. Without this the case would pass against a source '
              'that said nothing at all');
      expect(panel.announcements, hasLength(1),
          reason: 'five hundred priority-lane frames per client is a '
              'BufferDisconnect and a 4004 — a settings page evicting every '
              'panel in the plant and reporting it as backpressure (T-10-19). '
              'Nothing downstream of the sender would have merged them: the '
              'lane stores what it is given and the tick drains it verbatim');
      expect(panel.announcements.single, hasLength(500),
          reason: 'coalescing must not lose keys. A settings page filters this '
              'list for the section it is showing, so a frame that named only '
              'the first key would leave four hundred and ninety-nine forms '
              'holding values that are no longer stored');
      expect(panel.isOpen, isTrue,
          reason: 'and the panel is still connected, which is the whole point');
    });
  });

  group('a change by one client reaches another', () {
    test('two panels on one gateway, one edit', () async {
      final plant = await _Plant.start();
      final editor = await plant.panel();
      final watcher = await plant.panel();

      await editor.request(DataServiceMethods.prefSetInt,
          params: {'key': 'svn.chart.maxPoints', 'value': 800},
          what: 'one operator changing a setting');

      await within(_untilAnnounced(watcher),
          'the second panel hearing the first panel\'s edit',
          budget: _arrival);

      expect(watcher.announcements.single, ['svn.chart.maxPoints'],
          reason: 'DB-03 in one sentence: two operators have the same settings '
              'page open, and without this the second one\'s form holds stale '
              'values until they reopen it — at which point saving from there '
              'quietly overwrites the first one\'s edit');
      expect(editor.announcements.single, ['svn.chart.maxPoints'],
          reason: 'and the editor hears it too, from its own listener on the '
              'same shared store. Two sessions, two listeners, one store');
    });
  });

  group('a source that declares no preference store', () {
    test('serves everything else, and announces nothing', () async {
      final plant = await _Plant.withoutPreferences();
      final panel = await plant.panel();

      // Usable afterwards, not merely constructed: `UnsupportedError` is
      // caught where the subscription is taken, and a catch that swallowed the
      // rest of `_start` with it would leave a session that answered the
      // handshake and nothing else.
      final roots = await panel.request(DataServiceMethods.browseFetchRoots,
          params: const <String, Object?>{},
          what: 'a browse over a source with no preference store');
      await panel.barrier('a browse');

      expect(roots, isNotEmpty);
      expect(panel.announcements, isEmpty);
      expect(panel.isOpen, isTrue,
          reason: 'a declared absence is not a startup failure. The '
              'data-services sub-suite is skipped for such a source with a '
              'reason on the record, and refusing to serve it at all would '
              'turn that declaration into a dead gateway');
    });
  });
}

/// Completes when [panel] has been told about at least one change.
///
/// Turn-based against the panel's own frame log rather than a subscription,
/// because what is being waited for is a *notification*, which json_rpc_2
/// hands to a handler this file deliberately does not register — the raw frame
/// is the claim.
Future<void> _untilAnnounced(_Panel panel) async {
  while (panel.announcements.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
