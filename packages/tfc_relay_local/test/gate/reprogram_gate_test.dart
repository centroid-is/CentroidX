/// **F24 — PLC reprogrammed.** The catalogue row, verbatim from
/// `f_row_registry.dart` (§7.9 via 09-PATTERNS §0):
///
/// injection: restart one upstream / reassign its NodeIds mid-session
/// expectation: no stale-handle read ever returns a value; affected keys bad-quality until re-browse completes; other PLCs unaffected
///
/// **What this row adds over 08-08.** 08-08's arms (`epoch_test.dart`,
/// `stale_handle_test.dart`) are single-link and in-package: they prove the
/// epoch, the four-step bump and the refused stale handle at the link layer.
/// What they cannot say is the end-to-end sentence — *a panel over a real
/// socket sees exactly this* — and the isolation clause, because a
/// single-link arm has no other PLC to leave untouched. So F24a is two links
/// and a real panel: one alias reprogrammed, one announcement, every pre-bump
/// handle refused, and the neighbour's values, qualities and subscription
/// never so much as flinch. F24b repeats the stale-handle discipline against
/// a server that **genuinely restarted** — 08-08's own fixture lever, driven
/// rather than rebuilt.
///
/// The epoch is opaque above `epoch.dart`: these cases compare it for
/// equality and print it, and never parse it, order it, or read a timestamp
/// out of it — a case that inspected it would be asserting something the
/// design deliberately does not promise.
@TestOn('vm')
@Tags(['gate'])
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/gate_b_fixture.dart';
import '../support/keymap_fixtures.dart' show opcUaEntry;
import '../support/opcua_server_fixture.dart';

/// The two aliases of the fake-link arm. Fifty keys each: large enough that
/// "one announcement" and "one per key" are fifty apart, and the size 08-08's
/// re-browse count was proven at.
const String bumpedAlias = 'ST101';
const String untouchedAlias = 'ST201';
const int pageSize = 50;

/// F24b's real-server spelling (the fixture namespace is the server's, not
/// the fake page's).
const String realKey = 'ST101.CN01.MOT01.speed';
const String realWriteKey = 'ST101.CN01.MOT01.setpoint';

/// Generous: nothing in this file is a latency measurement.
const Duration generous = Duration(seconds: 10);

/// The keymapping entry F24b's link resolves against — the shape
/// `stale_handle_test.dart:49-53` uses, at the fixture's namespace.
KeyMappingEntry realMappingFor(String key) {
  final node = OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
    ..serverAlias = bumpedAlias;
  return KeyMappingEntry()..opcuaNode = node;
}

void main() {
  test(
      'F24a: a program download degrades exactly its own alias, announces '
      'once, refuses every pre-bump handle — and the PLC next to it never '
      'notices', () async {
    final fixture = await gateBFixture(
      panels: 1,
      aliases: const [bumpedAlias, untouchedAlias],
      keysPerAlias: pageSize,
    );
    final bumped = fixture.linkFor(bumpedAlias);
    final neighbour = fixture.linkFor(untouchedAlias);
    final panel = fixture.panel;
    final bumpedPage = gateBPage(bumpedAlias, pageSize);
    final neighbourPage = gateBPage(untouchedAlias, pageSize);

    // ---------------------------------------------------- anti-vacuity first
    // A ref minted BEFORE the bump answers with a real value, so "refused
    // after the bump" cannot be "refused always".
    final preRef =
        bumped.resolve(bumpedPage.first, opcUaEntry(alias: bumpedAlias))!;
    final beforeBump = await bumped.read(preRef, deadline: generous);
    expect(beforeBump.quality, Quality.good,
        reason: 'the pre-bump handle must answer while its epoch is current, '
            'or every refusal below is a link that simply broke');
    expect(beforeBump.value, isNotNull);

    // Both aliases' keys are advancing on the panel — the plant is busy on
    // BOTH sides of the isolation clause.
    final bumpedAt = panel.client.read(bumpedPage.first)?.value;
    final neighbourAt = panel.client.read(neighbourPage.first)?.value;
    await until(
      'both aliases\' keys advancing on the panel before the bump',
      () =>
          panel.client.read(bumpedPage.first)?.value != bumpedAt &&
          panel.client.read(neighbourPage.first)?.value != neighbourAt,
      budget: generous,
    );

    // The neighbour's subscription, held across the whole window. Every
    // delivery is recorded with its quality; the count is the "seq" whose
    // advance proves the subscription was never interrupted.
    final neighbourSeen = <DynamicValue>[];
    final neighbourSub =
        panel.client.subscribe(neighbourPage.first).listen(neighbourSeen.add);
    addTearDown(neighbourSub.cancel);

    // The ledger starts here. Unlike the e2e fixture's OPC UA leg, the fake
    // links reach `connected` during `plant.start()` — before any panel
    // session exists — so there are no startup announcements to wait out;
    // the clear is belt-and-braces against a reconnect landing one.
    panel.statuses.clear();

    final birthsBefore = bumped.birthCount;
    final epochBefore = bumped.epoch;
    final seqAtBump = neighbourSeen.length;

    // ------------------------------------------------------------- the bump
    bumped.bumpEpoch();
    final epochAfter = bumped.epoch;
    print('F24a EPOCH before=$epochBefore after=$epochAfter');
    expect(epochAfter, isNot(epochBefore));

    // Exactly ONE `reprogrammed` status for the alias reaches the panel —
    // not one per key. Fifty keys and one announcement are fifty apart.
    await until(
      'the reprogrammed announcement reaching the panel',
      () => panel.statuses
          .any((s) => s.state == UpstreamLinkState.reprogrammed.wireName),
      budget: generous,
    );
    final reprogrammedStatuses = [
      for (final s in panel.statuses)
        if (s.state == UpstreamLinkState.reprogrammed.wireName) s,
    ];
    print('F24a announcements at the panel = ${panel.statuses.length}, '
        'reprogrammed = ${reprogrammedStatuses.length} '
        'for ${reprogrammedStatuses.first.alias}');
    expect(reprogrammedStatuses, hasLength(1),
        reason: 'the panel heard about a $pageSize-key reprogram '
            '${reprogrammedStatuses.length} times. One event must be one '
            'notification: the same shape at fifteen hundred keys is fifteen '
            'hundred frames in the instant the panel is redrawing every box '
            'they are all about');
    expect(reprogrammedStatuses.first.alias, bumpedAlias,
        reason: 'and it names WHICH PLC, or a four-PLC plant has learned '
            'only that something somewhere is wrong');

    // Degrade-before-announce, measured at the gateway the instant the
    // announcement is known to have been sent: no bumped key may still read
    // good. T-09-10 rides here too: the status text carries no endpoint or
    // credential.
    final stillGood = <String>[
      for (final key in bumpedPage)
        if (fixture.plant.read(key)?.quality.isGood ?? false) key,
    ];
    expect(stillGood, isEmpty,
        reason: 'the announcement went out while these keys still read good '
            'on the gateway: $stillGood — a panel acting on it reads a '
            'confident number from an address space that no longer exists');
    final statusError = reprogrammedStatuses.first.error ?? '';
    expect(statusError, isNot(contains('://')),
        reason: 'T-09-10: an endpoint in an operator-visible reason is '
            'plant-visible information disclosure (redactUpstreamError, '
            '08-06)');

    // Every one of the fifty keys reads badCommFault (522) at the PANEL, in
    // one batch, and stays there while the re-browse is outstanding.
    await until(
      'all $pageSize $bumpedAlias keys reading badCommFault on the panel',
      () => bumpedPage.every((key) =>
          panel.client.read(key)?.quality == Quality.badCommFault),
      budget: generous,
    );

    // Read, write AND subscribe against the pre-bump ref each fail to
    // answer a value.
    final staleRead = await bumped.read(preRef, deadline: generous);
    print('F24a STALE READ quality=${staleRead.quality.code} '
        'value=${staleRead.value}');
    expect(staleRead.value, isNull,
        reason: 'no stale-handle read ever returns a value — the handle may '
            'now name a different variable entirely, and answering from it '
            'is not a stale read but a confidently wrong one');
    expect(staleRead.quality.isGood, isFalse);
    expect(bumped.peek(preRef), isNull,
        reason: 'peek is the synchronous door into the same cache');

    final staleWrite = await bumped.write(preRef, DynamicValue.of(7),
        cmd: 'cmd-f24a-stale', deadline: generous);
    expect(staleWrite, isA<WriteRejected>(),
        reason: 'rejected, not unknown: nothing was sent, so there is no '
            'ambiguity about whether the plant moved');
    expect((staleWrite as WriteRejected).reason.kind, 'stale_handle');

    var staleStreamEnded = false;
    final staleSeen = <DynamicValue>[];
    final staleSub = bumped
        .subscribe(preRef)
        .listen(staleSeen.add, onDone: () => staleStreamEnded = true);
    addTearDown(staleSub.cancel);
    await until('the stale subscription to say its one bad word',
        () => staleSeen.isNotEmpty,
        budget: generous);
    expect(staleSeen.first.value, isNull);
    expect(staleSeen.first.quality.isGood, isFalse);
    expect(staleStreamEnded, isFalse,
        reason: 'an ended stream reads to a widget as a key that stopped '
            'changing');

    // The bump is not a reconnection: birthCount tells the truth about the
    // session while the announced state tells the truth about the handles.
    expect(bumped.birthCount, birthsBefore,
        reason: 'a reprogram read as a reconnection would double-count '
            'births and re-run every restore path for an event that is not '
            'a link loss');

    // ------------------------------------------- the re-browse, exactly one
    expect(bumped.reBrowses, 0,
        reason: 'no re-browse has completed yet — the keys above were '
            'asserted bad-quality UNTIL it does, which is only a window if '
            'it has not already closed');
    bumped.completeReBrowse();
    print('F24a re-browse count for the bump = ${bumped.reBrowses}');
    expect(bumped.reBrowses, 1,
        reason: 'one bump is one re-browse, across all $pageSize keys — '
            '08-08 measured a second subscription under fifty in-flight '
            'creates crashing the VM, and a browse storm on a restarted '
            'controller is T-08-31');

    // Recovery: the alias comes back as the plant re-delivers.
    await until(
      'the bumped alias reading good again after the re-browse',
      () => bumpedPage
          .every((key) => panel.client.read(key)?.quality.isGood ?? false),
      budget: generous,
    );

    // -------------------------------------- the isolation clause, both axes
    // Value AND quality: the neighbour's page never left good, and its
    // values track the plant driver — not merely "did not go bad" but "kept
    // being the live numbers".
    for (final key in neighbourPage) {
      final seen = panel.client.read(key)!;
      expect(seen.quality, Quality.good,
          reason: '$key on the untouched alias lost good quality during a '
              'neighbour\'s reprogram — the per-alias filter is the clause '
              '"other PLCs unaffected", and it just failed');
    }
    // "Keeps advancing" is a rate, not a single event: wait for several
    // more deliveries so a stream that survived the bump only to stall
    // afterwards cannot pass on the one push it got in first.
    await until(
      'the untouched alias\'s subscription delivering several more values',
      () => neighbourSeen.length >= seqAtBump + 3,
      budget: generous,
    );
    final seqAfter = neighbourSeen.length;
    print('F24a neighbour seq advance across the window = '
        '$seqAtBump -> $seqAfter');
    expect(seqAfter, greaterThan(seqAtBump),
        reason: 'the untouched alias\'s subscription must keep delivering '
            'across the whole window — an interrupted stream is an affected '
            'PLC whatever the qualities say');
    final badDeliveries = [
      for (final value in neighbourSeen)
        if (!value.quality.isGood) value.quality,
    ];
    expect(badDeliveries, isEmpty,
        reason: 'the neighbour\'s subscription delivered non-good qualities '
            'during the window: $badDeliveries');
    expect(neighbour.inner.statusNotifications, lessThanOrEqualTo(1),
        reason: 'the untouched link announced a state change during a '
            'neighbour\'s bump (beyond its own startup connect)');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'F24b: against a server that genuinely restarted, no stale-handle '
      'read, write or subscribe answers — and a freshly resolved ref does',
      () async {
    final fixture = await OpcUaServerFixture.start(
      valueKeys: const [realKey],
      writeKeys: const [realWriteKey],
    );
    addTearDown(fixture.dispose);
    final link = OpcUaUpstreamLink(
      alias: bumpedAlias,
      endpoint: fixture.endpoint,
      // The REAL epoch reader — that is the point of this arm.
      useIsolate: false,
    );
    addTearDown(link.dispose);
    await link.connect(deadline: generous);
    await until('the link to reach connected against the real server',
        () => link.state == UpstreamLinkState.connected,
        budget: const Duration(seconds: 90));

    fixture.setValue(realKey, 41);
    final staleRef = link.resolve(realKey, realMappingFor(realKey))!;
    // Subscribed, not merely resolved: the handle must have carried a real
    // reading before it is stranded, or "it stopped answering" would be the
    // only thing it ever did.
    final warmUp = link.subscribe(staleRef).listen((_) {});
    addTearDown(warmUp.cancel);
    await until('a first good reading through the doomed handle',
        () => link.peek(staleRef)?.quality == Quality.good,
        budget: const Duration(seconds: 90));
    final epochBefore = link.epoch;

    // 08-08's fixture lever, driven rather than rebuilt: a NEW server on the
    // same port, so `ServerStatus.StartTime` genuinely moves and the NodeId
    // space is genuinely rebuilt.
    await fixture.restart();
    await until('the link to notice it is talking to a different server',
        () => link.epoch != epochBefore,
        budget: const Duration(seconds: 90));
    final epochAfter = link.epoch;
    print('F24b EPOCH before=$epochBefore after=$epochAfter');
    expect(epochAfter, isNot(epochBefore),
        reason: 'two identical epochs mean the fixture stopped restarting '
            'and everything below would pass vacuously');
    expect(isUnreadableEpoch(epochAfter), isFalse,
        reason: 'the new server must have ANSWERED — an epoch bumped to '
            '"unreadable" proves only that the link lost its socket');

    final staleRead = await link.read(staleRef, deadline: generous);
    print('F24b STALE READ quality=${staleRead.quality.code} '
        'value=${staleRead.value}');
    expect(staleRead.value, isNull,
        reason: 'no stale-handle read ever returns a value');
    expect(staleRead.quality.isGood, isFalse);
    expect(link.peek(staleRef), isNull);

    final staleWrite = await link.write(staleRef, DynamicValue.of(7),
        cmd: 'cmd-f24b-stale', deadline: generous);
    expect(staleWrite, isA<WriteRejected>());
    expect((staleWrite as WriteRejected).reason.kind, 'stale_handle');

    var ended = false;
    final seen = <DynamicValue>[];
    final staleSub =
        link.subscribe(staleRef).listen(seen.add, onDone: () => ended = true);
    addTearDown(staleSub.cancel);
    await until('the stale subscription to answer badly and stay open',
        () => seen.isNotEmpty,
        budget: generous);
    expect(seen.first.value, isNull);
    expect(seen.first.quality.isGood, isFalse);
    expect(ended, isFalse);

    // Post-restart anti-vacuity: a handle minted under the NEW epoch answers
    // — the link is refusing STALE handles, not all of them.
    final freshRef = link.resolve(realKey, realMappingFor(realKey))!;
    expect(freshRef.epoch, epochAfter);
    fixture.setValue(realKey, 43);
    final fresh = await link.read(freshRef, deadline: generous);
    print('F24b FRESH READ quality=${fresh.quality.code} '
        'value=${fresh.value}');
    expect(fresh.quality, Quality.good);
    expect(fresh.value, 43);
  },
      tags: 'opcua',
      testOn: '!windows',
      timeout: const Timeout(Duration(minutes: 4)));
}
