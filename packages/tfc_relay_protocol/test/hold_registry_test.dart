/// The live-hold registry, on its own, with no plant and no pipe.
///
/// A hold is an operator's finger on a jog button. The safety property runs
/// backwards from everything else in this package: nothing has to *arrive* for
/// the machine to stop — the counter has to **stop advancing**, and the PLC's
/// own deadman window (~1 s, ~10 missed ticks at 10 Hz) does the rest. Every
/// arm below is shaped by that inversion.
///
/// Deliberately free of `dart:io` so the whole file runs under `-p chrome` as
/// well as on the VM: web is a hard constraint for this project, and 18-01
/// found two forms of a helper that agreed on the VM and disagreed under
/// dart2js. The structural arms that must read source live in
/// `hold_registry_source_test.dart`, which is `@TestOn('vm')` for that reason
/// alone.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

const String _key = 'ST101.CN01.MOT01.jog';
const String _other = 'ST201.CN07.MOT02.jog';

/// One write the registry asked for, recorded in order.
typedef _Write = ({String key, int counter});

/// A feed that can apply, reject, answer unknown, throw, or never answer.
///
/// No plant, no pipe, no logger doing anything real — the point of a registry
/// that takes only "how to put a number on a tag" is that its arms cost
/// nothing to run.
final class _FakeFeed {
  final List<_Write> writes = <_Write>[];
  final List<_Write> ticks = <_Write>[];

  /// What the next engage answers. Releases always apply unless [stallZero] or
  /// [throwOnZeroFor] says otherwise.
  WriteResult Function(String key, int counter)? answer;

  /// When true, a release write (counter 0) returns a future that never
  /// completes — the stalled link that caused the teardown.
  bool stallZero = false;

  /// Keys whose release write throws on the way out.
  final Set<String> throwOnZeroFor = <String>{};

  /// Keys whose engage write throws on the way out.
  final Set<String> throwOnEngageFor = <String>{};

  /// Never completed, and never completed on purpose: arms 8 and 9 both hang
  /// their assertion off a release that has not answered yet.
  final Completer<WriteResult> _stalled = Completer<WriteResult>();

  Future<WriteResult> call(String key, int counter) {
    writes.add((key: key, counter: counter));
    if (counter == 0) {
      if (throwOnZeroFor.contains(key)) {
        throw StateError('the release write for "$key" blew up on the way out');
      }
      if (stallZero) return _stalled.future;
      return Future<WriteResult>.value(
          WriteApplied('release-$key', readback: 0, at: 1));
    }
    if (throwOnEngageFor.contains(key)) {
      throw StateError('the engage write for "$key" blew up on the way out');
    }
    final custom = answer;
    if (custom != null) {
      return Future<WriteResult>.value(custom(key, counter));
    }
    return Future<WriteResult>.value(
        WriteApplied('engage-$key', readback: counter, at: 1));
  }

  void tick(String key, int counter) => ticks.add((key: key, counter: counter));
}

HoldRegistry _registryOver(
  _FakeFeed feed, {
  required bool awaitReleases,
  void Function(String message, Object? error)? onLostWrite,
}) =>
    HoldRegistry(
      feed: feed.call,
      onTick: feed.tick,
      awaitReleases: awaitReleases,
      onLostWrite: onLostWrite,
    );

/// Lets a fire-and-forget release settle without waiting on anything.
Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('the engage', () {
    test('1. an applied engage produces a held handle and one live hold',
        () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);

      final hold = await registry.engage(_key);

      expect(hold.isHeld, isTrue);
      expect(hold.engagement, isA<WriteApplied>());
      expect(hold.counter, 1);
      expect(registry.liveHolds, 1);
      expect(feed.writes, <_Write>[(key: _key, counter: 1)],
          reason: 'the engage is one write, of the start counter, on the key '
              'that was passed in. There is exactly one key and it is that '
              'one: the tag IS the deadman counter');
    });

    test('2. a rejected engage produces an inert handle and zero live holds',
        () async {
      final feed = _FakeFeed()
        ..answer = (key, counter) => WriteRejected(
            'engage-$key', const WriteReason('Bad_NotWritable'));
      final registry = _registryOver(feed, awaitReleases: false);

      final hold = await registry.engage(_key);

      expect(hold.isHeld, isFalse);
      expect(hold.engagement, isA<WriteRejected>());
      expect(registry.liveHolds, 0);
      expect(await hold.onReleased, HoldEnded.refused,
          reason: 'a hold that was never taken comes back already released, '
              'so a caller can await onReleased uniformly without first '
              'inspecting the engagement');
    });

    test('3. an unknown engage is treated exactly as a refusal', () async {
      final feed = _FakeFeed()
        ..answer = (key, counter) => WriteUnknown(
            'engage-$key', const WriteReason('plc_timeout'));
      final registry = _registryOver(feed, awaitReleases: false);

      final hold = await registry.engage(_key);

      expect(hold.isHeld, isFalse);
      expect(registry.liveHolds, 0);
      expect(await hold.onReleased, HoldEnded.refused,
          reason: 'deliberate, and not over-caution: a hold you cannot be '
              'sure the plant took is one you must not feed, because the '
              'operator would be holding a button that may be doing nothing '
              'while the panel tells them it is doing something');
    });

    test('4. a throwing engage does not throw out of engage', () async {
      final feed = _FakeFeed()..throwOnEngageFor.add(_key);
      final reports = <String>[];
      final registry = _registryOver(feed,
          awaitReleases: false,
          onLostWrite: (message, error) => reports.add(message));

      // The assertion is that this line does not throw. `engage` returning at
      // all is the arm; everything below describes what it returned.
      final hold = await registry.engage(_key);

      expect(hold.isHeld, isFalse);
      expect(registry.liveHolds, 0);
      expect(hold.engagement, isA<WriteUnknown>());
      expect((hold.engagement as WriteUnknown).reason.kind, 'write_path_failed',
          reason: 'a throw out of the engage reaches the page as "something '
              'went wrong", and the page has a jog button to decide about '
              'either way. The honest report of a bug on the write path is '
              'still "nobody knows"');
      expect(reports, isNotEmpty,
          reason: 'a swallowed throw that nothing reports is a bug nobody '
              'ever hears about');
    });

    test('5. two holds on the same key are two entries', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);

      final first = await registry.engage(_key);
      final second = await registry.engage(_key);

      expect(first.isHeld, isTrue);
      expect(second.isHeld, isTrue);
      expect(identical(first, second), isFalse);
      expect(registry.liveHolds, 2,
          reason: 'a Set by identity, not a map keyed by tag. Two pages may '
              'legitimately hold two different machines, and a map keyed by '
              'key would silently drop one of two holds on the same tag — '
              'leaving a handle whose owner still believes it will be '
              'released on teardown');
    });
  });

  group('membership', () {
    test('6. membership drops synchronously on release', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);
      final hold = await registry.engage(_key);
      expect(registry.liveHolds, 1);

      final pending = hold.release();

      expect(registry.liveHolds, 0,
          reason: 'already decremented when release()\'s future is RETURNED, '
              'not a microtask later. The synchronous form removes the '
              'ordering trap that forces a clear() before the teardown loop');
      await pending;
    });
  });

  group('the teardown', () {
    test('7. releaseAll releases every live hold and empties the set',
        () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: true);
      final first = await registry.engage(_key);
      final second = await registry.engage(_other);

      await registry.releaseAll();

      expect(registry.liveHolds, 0);
      expect(first.isHeld, isFalse);
      expect(second.isHeld, isFalse);
      expect(await first.onReleased, HoldEnded.disposed);
      expect(await second.onReleased, HoldEnded.disposed);
      expect(
          feed.writes.where((w) => w.counter == 0).map((w) => w.key).toSet(),
          <String>{_key, _other},
          reason: 'one of two live holds released and the other forgotten is '
              'a machine still being fed by an object that no longer exists');
    });

    test('8. releaseAll(awaitReleases: false) returns before a slow feed '
        'completes', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);
      final hold = await registry.engage(_key);
      feed.stallZero = true;

      var returned = false;
      await registry.releaseAll().then((_) => returned = true);

      expect(returned, isTrue,
          reason: 'tfc_dart\'s behaviour, and it must survive the move '
              'byte-for-byte: the link that caused the teardown is the link '
              'the release would be waiting on');
      expect(hold.isHeld, isFalse);
      expect(await hold.onReleased, HoldEnded.disposed,
          reason: 'the counter stopped synchronously, which is the whole '
              'safety property — the release write\'s outcome is '
              'informational');
    });

    test('9. releaseAll(awaitReleases: true) does not return until every '
        'release has completed', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: true);
      await registry.engage(_key);
      feed.stallZero = true;

      var returned = false;
      unawaited(registry.releaseAll().then((_) => returned = true));
      await _settle();

      expect(returned, isFalse,
          reason: 'tfc_relay_local\'s behaviour, and it must survive too: '
              'every upstream write there is bounded by a REQUIRED deadline, '
              'so nothing on this path can hang, and a dispose that gave up '
              'half way leaves the thing it was disposing in a state nobody '
              'owns. Arms 8 and 9 MUST disagree — a shared registry that '
              'quietly picked one would be the behaviour change this phase '
              'promised not to make');
    });

    test('10a. a release that throws does not stop the others — fire-and-forget',
        () async {
      final feed = _FakeFeed()..throwOnZeroFor.add(_key);
      final reports = <String>[];
      final registry = _registryOver(feed,
          awaitReleases: false,
          onLostWrite: (message, error) => reports.add(message));
      final broken = await registry.engage(_key);
      final ok = await registry.engage(_other);

      await registry.releaseAll();
      await _settle();

      expect(broken.isHeld, isFalse);
      expect(ok.isHeld, isFalse);
      expect(await ok.onReleased, HoldEnded.disposed,
          reason: 'a teardown that abandons the remaining holds because one '
              'write failed is the one shape of this feature that could hurt '
              'somebody');
      expect(feed.writes.where((w) => w.counter == 0).length, 2);
      expect(reports, isNotEmpty);
    });

    test('10b. a release that throws does not stop the others — awaited',
        () async {
      final feed = _FakeFeed()..throwOnZeroFor.add(_key);
      final registry = _registryOver(feed, awaitReleases: true);
      final broken = await registry.engage(_key);
      final ok = await registry.engage(_other);

      await registry.releaseAll();

      expect(broken.isHeld, isFalse);
      expect(ok.isHeld, isFalse);
      expect(await ok.onReleased, HoldEnded.disposed);
      expect(registry.liveHolds, 0);
    });

    test('11. releaseAll is idempotent', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: true);
      final hold = await registry.engage(_key);

      await registry.releaseAll();
      final afterFirst = feed.writes.length;
      await registry.releaseAll();

      expect(feed.writes.length, afterFirst,
          reason: 'a disconnect racing an operator\'s finger must not put two '
              'zeros on the wire');
      expect(registry.liveHolds, 0);
      expect(await hold.onReleased, HoldEnded.disposed);
    });
  });

  // Two arms beyond the plan's eleven. Both pin a property the extraction
  // could silently take away, and neither is covered by the eleven above.

  group('the seam the registry does NOT own', () {
    test('12. a tick goes to the injected tick sink and never to the feed',
        () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);
      final hold = await registry.engage(_key);
      final afterEngage = feed.writes.length;

      hold.tick();
      hold.tick();
      await _settle();

      expect(feed.ticks,
          <_Write>[(key: _key, counter: 2), (key: _key, counter: 3)]);
      expect(feed.writes.length, afterEngage,
          reason: 'THE reason onTick is a separate injected function rather '
              'than the feed fired-and-forgotten. tfc_relay_local\'s tick '
              'path deliberately bypasses the outcome log and passes '
              'confirmByReading: false; tfc_dart\'s is the full write path. '
              'A registry that derived the tick from the feed would have '
              'silently moved every gateway tick into the outcome log, which '
              'is difference 4 and is a POLICY decision, not a merge');
    });

    test('13. the counter is minted here: tick takes no argument and the '
        'registry offers no way to write one', () async {
      final feed = _FakeFeed();
      final registry = _registryOver(feed, awaitReleases: false);
      final hold = await registry.engage(_key);

      hold.tick();
      await _settle();

      expect(feed.ticks.single.counter, 2,
          reason: 'the gateway mints the counter and a tick\'s n from the '
              'wire is discarded — you never trust a wire integer on a '
              'deadman tag. HoldHandle.tick() takes no argument at all, '
              'which is that rule expressed in the type, and HoldRegistry '
              'adds no second way to say it');
      expect(registry, isNot(isA<StateManApi>()),
          reason: 'tick must never become a member of the wire surface: a '
              'method there is a thing any connected client may invoke '
              'against any key, and a bare tick(key, n) is a write primitive '
              'with no engage in front of it');
    });
  });
}
