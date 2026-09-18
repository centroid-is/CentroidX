/// The two barriers a case passes through before it starts measuring, and the
/// question each of them has to ask.
///
/// Both are here because both got the question wrong in the same way, one
/// phase apart, and the symptom was the same both times: a budget that named a
/// property and bounded something else.
///
///  * [linkUp] did not exist, so the *first* await in every case on a socket
///    leg carried the connect, the handshake and the page's first snapshot
///    inside a 200 ms budget written for an in-process store. Measured on the
///    `RemoteStateMan` leg: 105 ms of transport, 0.3 ms of property.
///  * [arrived] existed but asked `read(key) != null`, which a source that
///    declares its page answers `true` for every key from the moment the
///    snapshot lands — with a [Quality.uncertainNotYetKnown] placeholder that
///    says, in as many words, that nothing has arrived. The barrier returned
///    instantly and guarded nothing.
///
/// The arms below are written against the reference implementation's levers
/// rather than a mock, so a change in what "the link is up" means shows up
/// here rather than only on a leg with a socket in it.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// An ordinary plant tag, in the vocabulary the rest of the suite uses.
const _speedKey = 'ST101.CN01.MOT01.speed';

void main() {
  group('linkUp', () {
    test('costs nothing on a source that is already up', () async {
      final api = FakeStateMan();
      addTearDown(api.dispose);

      // Not merely "it completed": the fast path must not await anything, or
      // every in-process leg pays a microtask per case for a barrier that had
      // nothing to wait for. A flag flipped in a later microtask is still
      // false when a synchronous return has already been taken.
      var afterwards = false;
      final done = linkUp(api).then((_) => afterwards);
      Future<void>.microtask(() => afterwards = true);

      expect(await done, isFalse,
          reason: 'the barrier yielded on a source whose link was already up');
    });

    test('waits for a link that comes up late, and lets it through', () async {
      final api = FakeStateMan();
      addTearDown(api.dispose);
      api.disconnectUpstream();

      final watch = Stopwatch()..start();
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        api.reconnectUpstream();
      });
      await linkUp(api);

      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(50),
          reason: 'the barrier returned before the link came back, so a case '
              'behind it would have started measuring against a dead source');
      expect(api.read(PipeKeys.connected)?.asBool, isTrue);
    });

    test('a link that never comes up fails by name, not by hanging', () async {
      final api = FakeStateMan();
      addTearDown(api.dispose);
      api.disconnectUpstream();

      await expectLater(
        () => linkUp(api, budget: const Duration(milliseconds: 50)),
        throwsA(isA<TestFailure>().having(
          (f) => f.message,
          'message',
          allOf(contains('the link coming up'), contains('50 ms')),
        )),
      );
    });

    test('the barrier and the property fail differently', () async {
      // The whole reason the wait is split in two. A single timeout around
      // both cannot say whether the link never came up or the value never
      // arrived over a link that did, and those are different faults with
      // different first questions.
      final down = FakeStateMan();
      addTearDown(down.dispose);
      down.disconnectUpstream();

      Object? barrierFailure;
      try {
        await linkUp(down, budget: const Duration(milliseconds: 50));
      } catch (error) {
        barrierFailure = error;
      }

      final up = FakeStateMan();
      addTearDown(up.dispose);
      await linkUp(up);

      Object? propertyFailure;
      try {
        await arrived(up, _speedKey, budget: const Duration(milliseconds: 50));
      } catch (error) {
        propertyFailure = error;
      }

      expect('$barrierFailure', contains('the link coming up'));
      expect('$propertyFailure', contains(_speedKey));
    });
  });

  group('arrived', () {
    test('a not-yet-known placeholder does not satisfy it', () async {
      final api = FakeStateMan();
      addTearDown(api.dispose);

      // Exactly what a gateway sends for a key the source *declares* and has
      // no reading for. Before the fix this made `read(key) != null` true and
      // the barrier returned on the spot, so the next notification the case
      // saw was the seed's own — the failure this helper's own doc is about,
      // arriving through the helper meant to prevent it.
      api.setValue(_speedKey, null, quality: Quality.uncertainNotYetKnown);
      expect(api.read(_speedKey), isNotNull,
          reason: 'the arm is vacuous unless the placeholder is really there');

      await expectLater(
        () => arrived(api, _speedKey, budget: const Duration(milliseconds: 50)),
        throwsA(isA<TestFailure>().having(
            (f) => f.message, 'message', contains(_speedKey))),
      );
    });

    test('a real reading satisfies it, placeholder or not', () async {
      final api = FakeStateMan();
      addTearDown(api.dispose);

      api.setValue(_speedKey, null, quality: Quality.uncertainNotYetKnown);
      api.setValue(_speedKey, 1450);

      await arrived(api, _speedKey, budget: const Duration(milliseconds: 50));
      expect(api.read(_speedKey)?.asInt, 1450);
    });

    test('a reading that is bad still counts as heard', () async {
      // "Heard from" is not "heard something good". A key the plant has
      // reported a comm fault for has been heard about, and a barrier that
      // waited for good news would hang on every degraded key in the suite.
      final api = FakeStateMan();
      addTearDown(api.dispose);

      api.setValue(_speedKey, 1450, quality: Quality.badCommFault);
      await arrived(api, _speedKey, budget: const Duration(milliseconds: 50));
    });
  });
}
