/// What the gateway's engage does when the write path misbehaves.
///
/// **Why this file exists.** Until 18-05 the gateway's `holdToRun` was
/// `await write(key, 1)` with nothing in front of it. 18-05 moved `tfc_dart`'s
/// engage throw-guard into the shared registry, so this side gained it — and a
/// guard adopted without an arm is a guard the next refactor removes. Writing
/// the arms turned up something the plan did not anticipate, so this file pins
/// what is actually true rather than what was expected:
///
///  1. **A link that throws was ALREADY handled**, by `write` itself, which
///     converts it to `WriteUnknown(gateway_lost_track)`. The adopted guard is
///     not what catches that, and it never was. Unpinned before this file.
///  2. **`write` throws deliberately on a disposed source** — "a lifecycle bug
///     in the caller, not a write outcome" — and the adopted guard would have
///     swallowed exactly that, handing back an inert handle where a loud
///     `StateError` used to come out. `holdToRun` now checks `_disposed` ahead
///     of the registry so the shipped behaviour survives; this file is what
///     stops that check being deleted as redundant.
///
/// A NEW file rather than an edit, because `hold_test.dart` has to pass with
/// zero lines changed by this plan.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// A link that answers everything the fake answers, and **throws** on `write`.
///
/// A decorator rather than a lever on `FakeUpstreamLink`, because a
/// throw-on-write switch on the shared fixture is a footgun for every other
/// suite that uses it, and because a link that throws is a defect in this
/// process rather than a fault this project models: `UpstreamLink`
/// implementations are supposed to answer, and the question below is what the
/// gateway does when one does not.
final class ThrowingWriteLink implements UpstreamLink {
  ThrowingWriteLink(this.inner);

  final FakeUpstreamLink inner;

  /// Flipped on after `start()`, so connecting and resolving still work.
  bool armed = false;

  @override
  Future<WriteResult> write(
    UpstreamRef ref,
    DynamicValue value, {
    required String cmd,
    required Duration deadline,
    bool hasExpect = false,
  }) {
    if (armed) {
      throw StateError('the link blew up on the way out — a defect in this '
          'process, not news about a plant');
    }
    return inner.write(ref, value,
        cmd: cmd, deadline: deadline, hasExpect: hasExpect);
  }

  @override
  String get alias => inner.alias;
  @override
  UpstreamLinkState get state => inner.state;
  @override
  Stream<UpstreamLinkState> get stateStream => inner.stateStream;
  @override
  String? get lastError => inner.lastError;
  @override
  String get epoch => inner.epoch;
  @override
  Stream<String> get epochStream => inner.epochStream;
  @override
  int get birthCount => inner.birthCount;
  @override
  DateTime? get lastDeathAt => inner.lastDeathAt;
  @override
  UpstreamRef? resolve(String key, Object mappingEntry) =>
      inner.resolve(key, mappingEntry);
  @override
  Stream<DynamicValue> subscribe(UpstreamRef ref) => inner.subscribe(ref);
  @override
  DynamicValue? peek(UpstreamRef ref) => inner.peek(ref);
  @override
  Future<DynamicValue> read(UpstreamRef ref, {required Duration deadline}) =>
      inner.read(ref, deadline: deadline);
  @override
  bool get supportsWrites => inner.supportsWrites;
  @override
  bool get supportsBrowse => inner.supportsBrowse;
  @override
  Future<void> connect({required Duration deadline}) =>
      inner.connect(deadline: deadline);
  @override
  Future<void> dispose() => inner.dispose();
  @override
  int get upstreamSubscriptionsCreated => inner.upstreamSubscriptionsCreated;
}

({LocalStateMan man, ThrowingWriteLink link}) buildFixture() {
  final fake = FakeUpstreamLink(
    alias: st101Alias,
    keys: const <String>[st101Key],
  );
  final link = ThrowingWriteLink(fake);
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      mappings: keyMappingsOf(const <String>[st101Key], alias: st101Alias),
    ),
    staleAfter: const Duration(seconds: 30),
  );
  return (man: man, link: link);
}

void main() {
  test('the live control: an ordinary engage still takes the hold', () async {
    final built = buildFixture();
    await built.man.start();
    addTearDown(built.man.dispose);

    final hold = await built.man.holdToRun(st101Key);

    expect(hold.isHeld, isTrue,
        reason: 'without this control every arm below would pass against a '
            'fixture that cannot engage at all, which is a guard-shaped hole '
            'rather than a guard');
    expect(hold.engagement, isA<WriteApplied>());
    await hold.release();
  });

  test('a link that THROWS on the engage does not throw out of holdToRun, and '
      'the handle is inert', () async {
    final built = buildFixture();
    await built.man.start();
    addTearDown(built.man.dispose);
    built.link.armed = true;

    // The assertion is that this line returns at all.
    final hold = await built.man.holdToRun(st101Key);

    expect(hold.isHeld, isFalse,
        reason: 'a hold whose engage could not even be SENT is one the plant '
            'certainly did not take, and a feedable handle here would be a '
            'deadman counter advancing on a machine nobody engaged');
    expect(hold.engagement, isA<WriteUnknown>(),
        reason: 'not rejected. A throw on the write path says nothing about '
            'what the plant did, and the honest report of a bug on the write '
            'path is still "nobody knows"');
    expect((hold.engagement as WriteUnknown).reason.kind, 'gateway_lost_track',
        reason: 'and this is the finding: `write` converts a link\'s throw '
            'ITSELF, so the reason is the write path\'s and not the engage '
            'guard\'s "write_path_failed". The guard 18-05 adopted from '
            'tfc_dart is defence in depth on this side, not the thing that '
            'catches a broken link — which is why sabotaging it leaves this '
            'package green');
    expect(await hold.onReleased, HoldEnded.refused);
  });

  test('a throwing engage leaves NOTHING live, so a teardown has nothing to '
      'release and writes nothing', () async {
    final built = buildFixture();
    await built.man.start();
    built.link.armed = true;

    final hold = await built.man.holdToRun(st101Key);
    expect(hold.isHeld, isFalse);

    // Disarmed, so a release write WOULD reach the link if the registry had
    // wrongly kept the refused handle live.
    built.link.armed = false;
    final before = built.link.inner.roundTrips;
    await built.man.dispose();

    expect(built.link.inner.roundTrips, before,
        reason: 'a refused-or-unknown engage must leave no live hold, so a '
            'dispose has nothing to zero — a zero written for a hold that was '
            'never taken is a write nobody commanded');
  });

  test('holdToRun on a DISPOSED source is still a StateError, not an inert '
      'handle', () async {
    final built = buildFixture();
    await built.man.start();
    await built.man.dispose();

    await expectLater(
        () => built.man.holdToRun(st101Key), throwsA(isA<StateError>()),
        reason: 'THE arm of this file. `write` throws here on purpose — "a '
            'lifecycle bug in the caller, not a write outcome" '
            '(local_state_man.dart:730, write_test.dart:541) — and the engage '
            'guard 18-05 adopted catches every throw, so without the '
            '_disposed check ahead of it this would come back as an inert '
            'handle carrying WriteUnknown(write_path_failed). That is a loud '
            'lifecycle bug converted into a jog button that silently does '
            'nothing, and it is a behaviour change this extraction was not '
            'supposed to make');
  });
}
