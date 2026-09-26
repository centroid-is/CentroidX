/// §C.4's quality table, through a deliberately broken wire.
///
/// Phase 2's `FaultProxy` is byte-level TCP and protocol-agnostic, so it works
/// against `opc.tcp` unchanged — and unlike the Phase 6 TLS legs, `cutMidFrame`
/// measures the right layer here: a server at `MessageSecurityMode.NONE` has no
/// TLS record to swallow the cut.
///
/// **Windows is out for the fixture's reason** (`@TestOn('!windows')`), not for
/// the proxy's.
@TestOn('!windows')
@Tags(['opcua', 'faults'])
library;

import 'dart:async';

import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

import 'opcua_link_test.dart'
    show alias, awaitConnected, mappingFor, setpointKey, speedKey;
import 'support/opcua_server_fixture.dart';

/// Everything that escaped to the zone during a case.
///
/// `mode_integrity_test.dart:396-419`'s pattern: a fault leg that "passes"
/// while throwing into the zone has proved nothing except that the assertion
/// ran first. Asserted empty at the end of the cases that can produce one.
final List<Object> escapedErrors = <Object>[];

/// Generous, for the paths that are not being measured.
const Duration generous = Duration(seconds: 10);

/// The timing bands, from STATE.md's Phase 2 handoff.
///
/// Linux 20 ms slack / 100 ms ceiling; everywhere else 75/150. This suite runs
/// on macOS and ubuntu, so it takes the looser pair and says so rather than
/// inventing a third. **No equality on a duration anywhere** — every
/// window-bounded arm prints its measured milliseconds and asserts a band.
const Duration bandSlack = Duration(milliseconds: 75);
const Duration bandCeiling = Duration(milliseconds: 150);

/// Waits for [predicate], polling, and returns how long it took.
///
/// A window, never an instant. Phase 2's handoff is explicit that a
/// `reject`/`flap` refusal may arrive one connect-time later, and the same is
/// true of every state this file waits for: OPC UA's own keep-alive and
/// `ClientWrapper`'s 2 s health timer both put a floor under how fast a
/// transition can be *observed*, which is a property of the protocol rather
/// than a slow test.
Future<Duration> until(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 45),
  String? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > within) {
      fail('${describe ?? 'condition'} never became true within '
          '${within.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

void main() {
  setUp(escapedErrors.clear);

  group('blackhole: the subscription stops delivering', () {
    test(
        'the link goes unhealthy BEFORE it goes disconnected, and the order is '
        'asserted inside a window', () async {
      // Order, not two instant reads. `unhealthy` is the frozen-session state —
      // TCP Established, channel formally open, nothing arriving — and it is
      // the whole reason `ClientWrapper`'s heartbeat exists: a purely
      // event-driven status never leaves `connected` here at all, because no
      // event is ever emitted.
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final link = OpcUaUpstreamLink(
          alias: alias,
          endpoint: fixture.endpoint,
          useIsolate: false,
          // The default 15 s stale window would make this case a 20-second
          // wait. The window is ClientWrapper's constant, so what this link
          // shortens is its own patience, not the wrapper's clock.
          staleAfter: const Duration(seconds: 2));
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final order = <UpstreamLinkState>[];
      final sub = link.stateStream.listen(order.add);
      addTearDown(sub.cancel);

      fixture.proxy!.blackhole();
      final elapsed = await until(
          () => order.contains(UpstreamLinkState.unhealthy),
          describe: 'the link never noticed the silence');
      print('BLACKHOLE unhealthy after ${elapsed.inMilliseconds} ms');

      expect(order.first, UpstreamLinkState.unhealthy,
          reason: 'a link whose values stopped arriving is unhealthy first. '
              'Going straight to disconnected would be a claim about the '
              'socket that is not true — it is still open, which is exactly '
              'what makes this failure invisible without a clock');
      expect(order.indexOf(UpstreamLinkState.unhealthy),
          lessThan(order.contains(UpstreamLinkState.disconnected)
              ? order.indexOf(UpstreamLinkState.disconnected)
              : order.length),
          reason: 'unhealthy precedes disconnected whenever both happen');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('every key on the link degrades to badCommFault, and a key already '
        'worse keeps its own verdict', () async {
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], writeKeys: [setpointKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final speedRef = link.resolve(speedKey, mappingFor(speedKey))!;
      final setpointRef = link.resolve(setpointKey, mappingFor(setpointKey))!;
      final speedSub = link.subscribe(speedRef).listen((_) {});
      final setpointSub = link.subscribe(setpointRef).listen((_) {});
      addTearDown(speedSub.cancel);
      addTearDown(setpointSub.cancel);
      fixture.setValue(speedKey, 5);
      await until(() => link.peek(speedRef)?.value == 5,
          describe: 'the first value never arrived');

      // One key is already errorConfig — the tag is gone, which is a different
      // instruction from "the link is down".
      fixture.deleteNode(setpointKey);
      await until(() => link.peek(setpointRef)?.quality == Quality.errorConfig,
          describe: 'the deleted tag never reported errorConfig');

      // One tag's disappearance is ONE tag. The neighbour is untouched, and
      // this assertion is what stops a "delete" that quietly takes the whole
      // link's cache with it.
      expect(link.peek(speedRef)!.quality, Quality.good,
          reason: 'deleting one node must not degrade its neighbours — a '
              'sanitize or address-space failure costs one tag, never a poll '
              'cycle');
      expect(link.peek(speedRef)!.value, 5);

      fixture.proxy!.killOnce();
      await fixture.proxy!.reject();
      final elapsed = await until(
          () => link.peek(speedRef)?.quality == Quality.badCommFault,
          describe: 'the live key never degraded');
      print('DEGRADE badCommFault after ${elapsed.inMilliseconds} ms');

      expect(link.peek(setpointRef)!.quality, Quality.errorConfig,
          reason: 'errorConfig means the tag is gone and waiting will not fix '
              'it; badCommFault means the link is down and waiting might. '
              'Overwriting the first with the second tells the operator to '
              'wait for something that is never coming back');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('kill once: the session drops and is re-established', () {
    test('every previously-subscribed key delivers again, the resubscribe is '
        'counted, and the key set is unchanged', () async {
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final control = await OpcUaServerFixture.start(valueKeys: [speedKey]);
      addTearDown(control.dispose);

      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      // The anti-vacuity arm: a link that was NOT killed, whose counter must
      // not move. Without it, an implementation that resubscribes everything
      // on a timer passes the case above.
      final controlLink = OpcUaUpstreamLink(
          alias: alias, endpoint: control.endpoint, useIsolate: false);
      addTearDown(controlLink.dispose);

      await link.connect(deadline: generous);
      await controlLink.connect(deadline: generous);
      await awaitConnected(link);
      await awaitConnected(controlLink);

      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      final controlRef =
          controlLink.resolve(speedKey, mappingFor(speedKey))!;
      final sub = link.subscribe(ref).listen((_) {});
      final controlSub = controlLink.subscribe(controlRef).listen((_) {});
      addTearDown(sub.cancel);
      addTearDown(controlSub.cancel);
      fixture.setValue(speedKey, 1);
      control.setValue(speedKey, 1);
      await until(() => link.peek(ref)?.value == 1);
      await until(() => controlLink.peek(controlRef)?.value == 1);

      final createsBefore = link.upstreamSubscriptionsCreated;
      final controlCreatesBefore = controlLink.upstreamSubscriptionsCreated;
      final keysBefore = link.subscribedKeys.toSet();

      fixture.proxy!.killOnce();
      final elapsed = await until(
          () => link.state != UpstreamLinkState.connected,
          describe: 'the link never noticed the reset');
      print('KILLONCE noticed after ${elapsed.inMilliseconds} ms');

      final back = await until(() => link.state == UpstreamLinkState.connected,
          describe: 'the session was never re-established');
      print('KILLONCE recovered after ${back.inMilliseconds} ms');

      fixture.setValue(speedKey, 2);
      final delivered =
          await until(() => link.peek(link.resolve(speedKey, mappingFor(speedKey))!)?.value == 2,
              describe: 'the key never delivered again after the resubscribe');
      print('KILLONCE delivering again after ${delivered.inMilliseconds} ms');

      expect(link.upstreamSubscriptionsCreated, greaterThan(createsBefore),
          reason: 'deltas of creates. There is no delete counter to balance '
              'against — the binding\'s onCancel discards the delete future');
      expect(link.subscribedKeys.toSet(), keysBefore,
          reason: 'a resubscribe re-establishes the same keys. A key set that '
              'grew means the old monitored items were never released and the '
              'PLC is now carrying two of everything');
      expect(controlLink.upstreamSubscriptionsCreated, controlCreatesBefore,
          reason: 'the control link was not killed. If its counter moved too, '
              'the case above is measuring a timer rather than a recovery');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        'BEHAVIOURAL no-retry: a write issued DURING the reconnect window '
        'reaches the wire exactly once, and never again afterwards', () async {
      // The static pins in freeze_test.dart count CALL SITES. This arm counts
      // what actually reached the server while `ClientWrapper` was
      // re-establishing a session underneath the adapter — which is the only
      // way to show that the wrapped client's reconnect logic stays
      // read/subscribe-side and never re-issues an in-flight write.
      //
      // "Never silently retried" is one of the three promises the whole
      // project is built on, and on a hold-to-run engage a re-issued write is
      // a jog nobody is holding.
      final fixture = await OpcUaServerFixture.start(
          writeKeys: [setpointKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final ref = link.resolve(setpointKey, mappingFor(setpointKey))!;
      // A first write, so the count below is a delta on a path known to work
      // rather than a number that might always have been zero.
      final first = await link.write(ref, DynamicValue.of(1),
          cmd: 'cmd-before', deadline: generous);
      expect(first, isA<WriteApplied>());
      expect(fixture.writeCount(setpointKey), 1);

      // Now break the wire and issue a write into the hole.
      fixture.proxy!.killOnce();
      final outcome = await link.write(ref, DynamicValue.of(99),
          cmd: 'cmd-during', deadline: const Duration(seconds: 2));

      final atOutcome = fixture.writeCount(setpointKey);
      print('NORETRY writes at outcome = $atOutcome');
      print('NORETRY outcome = ${outcome.runtimeType}');

      // Let the link fully reconnect and then some. If anything re-issues,
      // this is the window in which it would.
      await until(() => link.state == UpstreamLinkState.connected,
          describe: 'the link never came back');
      await Future<void>.delayed(const Duration(seconds: 3));
      final afterReconnect = fixture.writeCount(setpointKey);
      print('NORETRY writes after reconnect = $afterReconnect');

      expect(atOutcome, lessThanOrEqualTo(2),
          reason: 'one write before the fault and at most one attempt during '
              'it. Two attempts for one cmd is the auto-retry this project '
              'forbids at every layer');
      expect(afterReconnect, atOutcome,
          reason: 'ZERO attempts after the reconnect completed. A wrapper that '
              're-sends an unknown write on session recovery is exactly the '
              'shape the no-retry seam sweep is pointed at, and it would show '
              'up here as the count moving while nobody asked for anything');
      expect(outcome, isNot(isA<WriteApplied>()),
          reason: 'the request went into a wire that was being reset. Applied '
              'means applied AND read back, and neither happened');
      expect(outcome.cmd, 'cmd-during');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('restored, not yet re-read', () {
    test(
        'the keys read uncertainLastKnown and their values are still the old '
        'ones — a stale number, openly labelled', () async {
      // The operator-facing point of the entire quality model. Straight back
      // to good would republish an hour-old reading as current the instant the
      // socket reopened; blanking the value would throw away the only
      // information there is. Uncertain, with the number still on the screen,
      // is the honest third answer.
      final fixture = await OpcUaServerFixture.start(
          valueKeys: [speedKey], viaFaultProxy: true);
      addTearDown(fixture.dispose);
      final link = OpcUaUpstreamLink(
          alias: alias, endpoint: fixture.endpoint, useIsolate: false);
      addTearDown(link.dispose);
      await link.connect(deadline: generous);
      await awaitConnected(link);

      final ref = link.resolve(speedKey, mappingFor(speedKey))!;
      // **Observed on the stream, not by polling `peek`.** The recovery was
      // measured at ~200 ms end to end, and the uncertain window inside it is
      // the gap between the session reopening and the first re-read sample —
      // ~100 ms. A 25 ms poll misses it often enough to be a flake, and
      // widening the poll would be testing the sampler. Every published value
      // goes through the subscription, so the subscription is where the
      // sequence is asserted.
      final published = <DynamicValue>[];
      final sub = link.subscribe(ref).listen(published.add);
      addTearDown(sub.cancel);
      fixture.setValue(speedKey, 17);
      await until(() => link.peek(ref)?.value == 17);
      published.clear();

      fixture.proxy!.killOnce();
      await until(() => link.state != UpstreamLinkState.connected,
          describe: 'the link never noticed the reset');
      final recovered = await until(
          () => published.any((v) => v.quality == Quality.uncertainLastKnown),
          describe: 'the link never published uncertainLastKnown');
      print('RESTORED uncertain published after ${recovered.inMilliseconds} ms');
      print('RESTORED sequence = ${published.map((v) => '${v.quality}:${v.value}').toList()}');

      final uncertain =
          published.firstWhere((v) => v.quality == Quality.uncertainLastKnown);
      expect(uncertain.value, 17,
          reason: 'the old number stays, because it is the only number there '
              'is. What changes is that the gateway stops vouching for it — a '
              'stale number openly labelled, which is the operator-facing '
              'point of the whole quality model');
      expect(
          published.indexOf(uncertain),
          greaterThan(published.indexWhere(
              (v) => v.quality == Quality.badCommFault)),
          reason: 'and it comes AFTER the comms fault, not instead of it: '
              'down, then back but not yet re-read, then read');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('cut mid frame', () {
    test('a truncated opc.tcp frame produces a bad quality and nothing '
        'escapes to the zone', () async {
      // An `opc.tcp` server at MessageSecurityMode.NONE has no TLS record to
      // swallow the cut, so this lever measures the layer it claims to.
      final completer = Completer<void>();
      runZonedGuarded(() async {
        final fixture = await OpcUaServerFixture.start(
            valueKeys: [speedKey], viaFaultProxy: true);
        final link = OpcUaUpstreamLink(
            alias: alias, endpoint: fixture.endpoint, useIsolate: false);
        try {
          await link.connect(deadline: generous);
          await awaitConnected(link);
          final ref = link.resolve(speedKey, mappingFor(speedKey))!;
          final sub = link.subscribe(ref).listen((_) {});
          fixture.setValue(speedKey, 4);
          await until(() => link.peek(ref)?.value == 4);

          // Phase 2's handoff: cutAfterBytes is a getter/setter pair, so it is
          // set through the setter — a writer that pokes a field misses it.
          fixture.proxy!.cutMidFrame(64);
          final elapsed = await until(
              () => link.peek(ref)!.quality != Quality.good,
              describe: 'the truncated frame never degraded the key');
          print('CUTMIDFRAME degraded after ${elapsed.inMilliseconds} ms');

          expect(link.peek(ref)!.quality.isBad || link.peek(ref)!.quality.isError,
              isTrue,
              reason: 'a truncated frame is not a value. It is a bad quality, '
                  'and it must not be a throw that escapes to the zone');
          await sub.cancel();
        } finally {
          await link.dispose();
          await fixture.dispose();
        }
        completer.complete();
      }, (error, stack) {
        escapedErrors.add(error);
        if (!completer.isCompleted) completer.completeError(error);
      });
      await completer.future;

      expect(escapedErrors, isEmpty,
          reason: 'a fault leg that passes while throwing into the zone has '
              'proved only that its assertion ran first');
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
