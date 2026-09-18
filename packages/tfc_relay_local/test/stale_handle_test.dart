/// **F24: a stale handle never answers with a value.**
///
/// ROADMAP Phase 8, success criterion 2, verbatim:
///
/// > A change in a PLC's `ServerStatus.StartTime` bumps its epoch, forces
/// > re-browse, and marks its keys bad-quality; a read against a stale handle
/// > never returns a value (F24)
///
/// Phase 9 owns the F22–F28 edge-case gate and will want this exact scenario,
/// so it is named here in the file doc rather than remembered: **F24**, PLC
/// reprogram, stale handle. Grep for it.
///
/// What makes this file different from `epoch_test.dart` is the word *really*.
/// There the identity is injected, because a case about the ordering of four
/// steps should not also be a case about restarting a server. Here the server
/// genuinely goes down and a new one comes up on the same port, `StartTime`
/// genuinely moves, and the epoch the link computes is a **measurement** of
/// that rather than an assertion about a counter the test incremented itself.
/// Both epochs are printed on every run for that reason: a phase gate that
/// quotes two identical strings has caught a fixture that stopped restarting,
/// and the arms below would then all be passing against a link that simply
/// broke.
///
/// `@TestOn('!windows')` and the `opcua` tag for `opcua_link_test.dart:1-9`'s
/// reason: the CI matrix includes `windows-latest` and an in-process
/// open62541 `Server` is not run there.
@TestOn('!windows')
@Tags(['opcua'])
library;

import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'support/opcua_server_fixture.dart';

/// The plant's own spelling.
const String speedKey = 'ST101.CN01.MOT01.speed';
const String setpointKey = 'ST101.CN01.MOT01.setpoint';

/// This link's alias.
const String alias = 'ST101';

/// Generous: none of these cases is a latency measurement.
const Duration generous = Duration(seconds: 10);

/// The keymapping entry the router would hand `resolve`.
KeyMappingEntry mappingFor(String key) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = alias;
  return KeyMappingEntry()..opcuaNode = node;
}

/// Polls [predicate] until it holds or [within] runs out.
Future<void> until(bool Function() predicate, String what,
    {Duration within = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  group('against a server that really restarted', () {
    late OpcUaServerFixture fixture;
    late OpcUaUpstreamLink link;
    late UpstreamRef staleRef;
    late String epochBefore;
    late String epochAfter;

    setUp(() async {
      fixture = await OpcUaServerFixture.start(
        valueKeys: [speedKey],
        writeKeys: [setpointKey],
      );
      addTearDown(fixture.dispose);
      link = OpcUaUpstreamLink(
        alias: alias,
        endpoint: fixture.endpoint,
        // The REAL epoch reader. That is the point of this file.
        useIsolate: false,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await until(() => link.state == UpstreamLinkState.connected,
          'the link to reach connected');
      fixture.setValue(speedKey, 41);
      staleRef = link.resolve(speedKey, mappingFor(speedKey))!;
      // Subscribed, not merely resolved: the handle has to have carried a real
      // reading before it is stranded, or "it stopped answering" would be the
      // only thing it ever did.
      final warmUp = link.subscribe(staleRef).listen((_) {});
      addTearDown(warmUp.cancel);
      await until(() => link.peek(staleRef)?.quality == Quality.good,
          'a first good reading through the handle we are about to strand');
      epochBefore = link.epoch;

      // The event this whole mechanism exists for. `restart()` shuts the
      // server down and brings a NEW one up on the same port, so
      // `Server_ServerStatus_StartTime` (ns=0, i=2257) genuinely moves.
      //
      // **08-07 shipped this lever with no caller and no test and said so.**
      // Treating it as proven would make every assertion below rest on
      // unproven fixture code, so the epoch comparison at the end of this
      // setUp is not decoration: it is the arm that verifies the lever, in
      // the plan that first uses it.
      await fixture.restart();
      await until(() => link.epoch != epochBefore,
          'the link to notice it is talking to a different server');
      epochAfter = link.epoch;
      print('EPOCH before=$epochBefore after=$epochAfter');
      expect(epochAfter, isNot(epochBefore),
          reason: 'the fixture did not restart the way this test believes. '
              'Two identical epochs mean StartTime did not move, and every '
              'assertion in this file would then be passing vacuously');
      expect(isUnreadableEpoch(epochAfter), isFalse,
          reason: 'the new server must have ANSWERED — an epoch that bumped '
              'to "unreadable" would prove only that the link lost its socket');
    });

    test('a read through a stale handle answers bad quality and a NULL value',
        () async {
      final seen = await link.read(staleRef, deadline: generous);

      print('STALE READ quality=${seen.quality.code} value=${seen.value}');
      expect(seen.quality.isBad || seen.quality.isError, isTrue,
          reason: 'ROADMAP criterion 2: the keys are marked bad-quality');
      expect(seen.value, isNull,
          reason: 'and the value is gone with it. A bad quality on a stale '
              'number is still a stale number on a screen, and the handle may '
              'now name a different variable entirely — answering from it is '
              'not a stale read but a confidently wrong one');
      expect(link.peek(staleRef), isNull,
          reason: 'peek is the synchronous door into the same cache and it '
              'must be shut too');
    });

    test('a write through a stale handle is REJECTED and names the stale '
        'epoch', () async {
      final written = await link.write(staleRef, DynamicValue.of(7),
          cmd: 'cmd-f24-stale', deadline: generous);

      expect(written, isA<WriteRejected>(),
          reason: 'rejected, not unknown: nothing was sent, so there is no '
              'ambiguity about whether the plant moved. "It did not happen" '
              'and "I cannot tell" are different things to say to an operator '
              'standing next to the machine');
      final rejected = written as WriteRejected;
      expect(rejected.reason.kind, 'stale_handle');
      expect(rejected.reason.message, contains(epochBefore),
          reason: 'the handle\'s own epoch is named, so the person reading '
              'the message can see the two tokens differ without knowing '
              'anything about what is inside one');
      expect(rejected.reason.message, contains(epochAfter));
      print('STALE WRITE ${rejected.reason.kind}: ${rejected.reason.message}');
    });

    test('a subscribe through a stale handle emits a bad-quality value and '
        'does NOT end', () async {
      var ended = false;
      final seen = <DynamicValue>[];
      final subscription = link
          .subscribe(staleRef)
          .listen(seen.add, onDone: () => ended = true);
      addTearDown(subscription.cancel);

      await until(() => seen.isNotEmpty, 'the stale stream to say something');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(seen.first.quality.isBad || seen.first.quality.isError, isTrue);
      expect(seen.first.value, isNull);
      expect(ended, isFalse,
          reason: 'an ended stream is indistinguishable to a widget from a '
              'key that stopped changing — `AutoDisposingStream`\'s '
              'close-on-source-end (state_man.dart:2691) is on the '
              'do-not-inherit list');
    });

    test('a handle obtained AFTER the restart works normally against the same '
        'key', () async {
      // The anti-vacuity arm. Without it every assertion above passes against
      // an implementation that simply broke, and a link that answers nothing
      // ever would score four green cases.
      final freshRef = link.resolve(speedKey, mappingFor(speedKey))!;
      expect(freshRef.epoch, epochAfter);

      fixture.setValue(speedKey, 43);
      final seen = await link.read(freshRef, deadline: generous);

      print('FRESH READ quality=${seen.quality.code} value=${seen.value}');
      expect(seen.quality, Quality.good);
      expect(seen.value, 43);
    });

    test('a write through a handle obtained AFTER the restart reaches the '
        'server', () async {
      final freshRef = link.resolve(setpointKey, mappingFor(setpointKey))!;
      final before = fixture.writeCount(setpointKey);

      final written = await link.write(freshRef, DynamicValue.of(9),
          cmd: 'cmd-f24-fresh', deadline: generous);

      expect(written, isA<WriteApplied>(),
          reason: 'the second half of anti-vacuity: the write path is refusing '
              'STALE handles, not all of them');
      expect(fixture.writeCount(setpointKey), before + 1,
          reason: 'counted at the SERVER, which is the only place that can '
              'tell a write that happened from one the adapter says happened');
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}
