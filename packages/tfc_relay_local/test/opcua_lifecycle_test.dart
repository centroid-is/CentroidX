/// What the OPC UA adapter owns, and what it does while it is being torn down.
///
/// **Three lifetime findings from 08-REVIEW, and one subject for all of them.**
/// Every case here uses `FakeUaClient` rather than the real in-process server,
/// and `support/fake_ua_client.dart` argues that choice at length: the failure
/// WR-04 describes is a SEGV, which kills a test process rather than failing a
/// case, and the window it happens in is microseconds wide against a real
/// server and a lever here.
///
/// None of these cases says anything about the OPC UA protocol. They are about
/// this package's own bookkeeping — which future it awaits, which object it
/// deletes, and how much of a deadline it is allowed to spend.
library;

import 'dart:async';

import 'package:open62541/open62541.dart' as ua;
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, OpcUANodeConfig;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_ua_client.dart';

const String alias = 'ST101';
const String key = 'ST101.CN01.MOT01.speed';

/// A mapping entry the OPC UA adapter will claim.
KeyMappingEntry nodeEntry({String serverAlias = alias}) => KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'GVL.$key')
        ..serverAlias = serverAlias,
    );

({OpcUaUpstreamLink link, FakeUaClient client}) build({
  Duration epochDeadline = const Duration(seconds: 5),
  EpochInputsReader? epochReader,
}) {
  final client = FakeUaClient();
  final link = OpcUaUpstreamLink(
    alias: alias,
    endpoint: 'opc.tcp://127.0.0.1:4840',
    client: client,
    epochDeadline: epochDeadline,
    epochReader: epochReader ?? _quietEpoch,
    // **The driver is parked, and that is what makes the WR-04 arms about
    // WR-04.** At the 10 ms default the iterate loop runs `_reopenSessionIf
    // Needed` within a tick, sees a wrapper that is not connected yet, and
    // dials — putting a *second* connect into `_inFlight`, which `dispose`
    // has always awaited. That accidental cover made the first version of
    // these cases pass with `connect` untracked, which is precisely the
    // defect they exist to catch. A period longer than any case here means
    // the only future in flight is the one under test.
    iteratePeriod: const Duration(seconds: 30),
  );
  return (link: link, client: client);
}

/// An epoch reader that answers instantly and identically, so a case about
/// something else is not also a case about the epoch.
Future<EpochInputs> _quietEpoch(ua.ClientApi client,
        {required Duration deadline, ua.NodeId? buildStampNode}) async =>
    EpochInputs(startTime: DateTime.utc(2026), namespaceArrayHash: 'abc');

void main() {
  group('WR-04: dispose() racing an in-flight connect()', () {
    test('dispose waits for the connect it landed inside, and the client is '
        'deleted only after it', () async {
      final built = build();
      built.client.connectDelay = const Duration(milliseconds: 120);

      // Not awaited: this is the caller that tears down while `start()` is
      // still walking its link list, which a failing PLC holds open for tens
      // of seconds.
      //
      // The flag is armed BEFORE the dispose, not after it. Asking afterwards
      // cannot tell "dispose waited" from "the connect happened to finish
      // first", and that ambiguity is what made the first version of this case
      // pass against the defect.
      var connectSettled = false;
      final connecting = built.link.connect(deadline: const Duration(seconds: 5));
      unawaited(connecting.then<void>((_) => connectSettled = true,
          onError: (Object _) => connectSettled = true));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connectSettled, isFalse,
          reason: 'anti-vacuity: the connect must genuinely still be running '
              'when the dispose lands, or this case is about nothing');

      await built.link.dispose();

      // Deleting the native client while a `connect` or a `subscriptionCreate`
      // is still crossing FFI against it walks freed memory and SEGVs the VM
      // rather than failing — the hazard `_inFlight` was added for, through
      // the one entry point it did not cover.
      expect(connectSettled, isTrue,
          reason: 'dispose() returned while its own connect was still in '
              'flight, which is the use-after-free window in one sentence');
      expect(built.client.deleted, isTrue);
    });

    test('a dispose landing between the session and the subscription stops the '
        'connect where it stands', () async {
      final built = build();
      built.client.subscriptionDelay = const Duration(milliseconds: 120);

      final connecting = built.link.connect(deadline: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await built.link.dispose();
      await connecting;

      expect(built.client.deleted, isTrue);
      expect(built.link.reBrowses, 0,
          reason: '`_disposed` is re-read after every await, so nothing '
              'downstream of the subscription runs — an epoch read against a '
              'deleted client is the same SEGV one call later');
    });

    test('connect after dispose is still a StateError, not a silent no-op',
        () async {
      final built = build();
      await built.link.dispose();
      expect(() => built.link.connect(deadline: const Duration(seconds: 1)),
          throwsStateError);
    });

    test('a client created while a dispose was landing is deleted rather than '
        'stranded', () async {
      // The narrow window before `_client` is assigned: `dispose` cannot see
      // the client to release it, so the connect has to release it itself.
      final built = build();
      built.client.connectDelay = const Duration(milliseconds: 60);
      final connecting = built.link.connect(deadline: const Duration(seconds: 5));
      await built.link.dispose();
      await connecting;
      expect(built.client.deleteCount, greaterThanOrEqualTo(1));
      expect(built.client.deleteCount, lessThanOrEqualTo(1),
          reason: 'and exactly once — a double delete on a native client is '
              'the same free-twice bug from the other end');
    });
  });

  group('WR-03: an injected client is owned by the link', () {
    test('dispose deletes it, so a credentialed gateway can exit', () async {
      final built = build();
      await built.link.connect(deadline: const Duration(seconds: 5));
      await built.link.dispose();

      expect(built.client.deleteCount, 1,
          reason: 'buildUpstreamLink injects a client whenever the config '
              'names a username/password or a certificate pair, and at the '
              'default useIsolate: true that is a spawned ClientIsolate. A '
              'live isolate keeps the VM alive: the gateway logged "stopping", '
              'finished stop(), and did not exit until the container runtime '
              'escalated to SIGKILL');
    });

    test('dispose is still idempotent, and does not delete twice', () async {
      final built = build();
      await built.link.connect(deadline: const Duration(seconds: 5));
      await built.link.dispose();
      await built.link.dispose();
      expect(built.client.deleteCount, 1);
    });
  });

  group('WR-05: one deadline means one deadline', () {
    test('connect spends a single budget across its phases rather than one '
        'each', () async {
      // The REAL epoch reader, so the third phase spends real time too —
      // with a reader that answers instantly the arithmetic below is the same
      // whether or not the budget is shared, which is exactly how a vacuous
      // version of this case passes.
      final built = build(epochReader: readEpochInputs);
      // Every phase slower than its share. Under one budget the method is
      // bounded at the budget; under one deadline EACH it is
      // connect + subscribe + three epoch reads, all at the full number.
      built.client.connectDelay = const Duration(milliseconds: 200);
      built.client.subscriptionDelay = const Duration(milliseconds: 200);
      built.client.readDelay = const Duration(milliseconds: 200);

      final watch = Stopwatch()..start();
      await built.link
          .connect(deadline: const Duration(milliseconds: 300))
          .then<void>((_) {}, onError: (Object _) {});
      watch.stop();
      addTearDown(built.link.dispose);

      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)),
          reason: 'the doc said "bounded by connectDeadline", which reads as a '
              'bound on the call. It was applied separately to client.connect, '
              'to subscriptionCreate and then handed whole to the epoch reader '
              '— about five times the number a deployment typed, and '
              'LocalStateMan.start multiplies that again by the link count');
    });

    test('the epoch reader shares one budget across its three reads', () async {
      final client = FakeUaClient()..readDelay = const Duration(milliseconds: 80);

      final watch = Stopwatch()..start();
      final inputs = await readEpochInputs(client,
          deadline: const Duration(milliseconds: 100),
          buildStampNode: ua.NodeId.fromString(4, 'GVL.build'));
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(milliseconds: 200)),
          reason: 'three sequential reads each carrying the FULL deadline is '
              'three times the bound, and it happens inside connect, which is '
              'itself inside a sequential walk of every link');
      expect(inputs, isNotNull,
          reason: 'and it still answers rather than throwing: a server that '
              'will not say who it is has told us something, and the reading '
              'is unreadable rather than absent');
    });
  });

  group('WR-09: a stale-handle subscribe does not leak its controller', () {
    test('the one-shot feed is closed by dispose', () async {
      final built = build();
      await built.link.connect(deadline: const Duration(seconds: 5));
      final ref = built.link.resolve(key, nodeEntry())!;

      // Every held handle goes stale at once — which is what a PLC download
      // does, and is therefore when this path runs once per subscribed key.
      built.link.debugBumpEpoch();
      expect(built.link.resolve(key, nodeEntry())!.epoch, isNot(ref.epoch),
          reason: 'anti-vacuity: the handle has to be stale');

      final feeds = <Stream<DynamicValue>>[
        for (var i = 0; i < 3; i++) built.link.subscribe(ref),
      ];
      // A stale feed emits one bad value and then stays OPEN, so a drain
      // completes only once `dispose` closes the controller behind it. That
      // is the assertion: without WR-09's fix these futures never complete.
      final closed = <bool>[for (var i = 0; i < feeds.length; i++) false];

      final drains = <Future<void>>[
        for (var i = 0; i < feeds.length; i++)
          feeds[i].drain<void>().then((_) => closed[i] = true),
      ];

      await built.link.dispose();
      await Future.wait(drains).timeout(const Duration(seconds: 2),
          onTimeout: () => throw StateError(
              'a stale-handle feed was never closed: dispose walks _monitors '
              'and this controller is not in it, so it and its listeners '
              'outlive the link (08-REVIEW WR-09)'));

      expect(closed, everyElement(isTrue));
    });
  });
}
