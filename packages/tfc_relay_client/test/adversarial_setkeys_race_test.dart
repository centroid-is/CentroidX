@TestOn('vm')
@Tags(['ws'])

/// Adversarial round 2 (client): two page changes inside one round trip.
///
/// `RemoteStateMan.setKeys` mutates the page's key set in place and then
/// calls `ResyncEngine.onResync`, which joins any establishment already in
/// flight for the same subscription (`_inFlight[sub.subId] ??=`). The subscribe
/// frame for the FIRST call carries the first key set, materialised at send
/// time; the second call sends nothing at all and completes when the first
/// snapshot lands. Client and gateway then agree on a sequence, so no tick
/// ever earns a rebuild — the second page never populates until the next
/// reconnect, and the first page's values stay readable in the store.
library;

import 'package:test/test.dart';

import 'support/fault_fixture.dart';
import 'support/gate_bands.dart';

const String _a = 'ST101.CN01.MOT01.speed';
const String _b = 'ST201.CN04.MOT01.speed';

Future<bool> _within(Duration budget, bool Function() done) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

void main() {
  group('setKeys while an establishment is in flight', () {
    test('control: two page changes awaited one after the other both land',
        () async {
      final fixture = await faultFixture(
        keys: const <String>{},
        seed: (plant) {
          plant.setValue(_a, 11);
          plant.setValue(_b, 22);
        },
      );
      await until('the link', () => fixture.client.isReady);

      await fixture.client.setKeys({_a}).timeout(recovery);
      expect(fixture.client.read(_a)?.value, 11);
      await fixture.client.setKeys({_b}).timeout(recovery);
      expect(fixture.client.read(_b)?.value, 22);
      expect(fixture.client.read(_a)?.value, isNull,
          reason: 'the page that was navigated away from still shows values');
    });

    test(
        'the second page change joins the first\'s in-flight subscribe: its '
        'keys are never sent, and the page never populates', () async {
      final fixture = await faultFixture(
        keys: const <String>{},
        seed: (plant) {
          plant.setValue(_a, 11);
          plant.setValue(_b, 22);
        },
      );
      await until('the link', () => fixture.client.isReady);

      // Page A, then page B before A's snapshot has landed — an operator
      // tapping through two pages on a slow link, or a page change during a
      // reconnect's own resubscribe.
      final first = fixture.client.setKeys({_a});
      final second = fixture.client.setKeys({_b});
      await Future.wait([first, second]).timeout(recovery);

      expect(fixture.client.subscribedKeys, {_b},
          reason: 'the client believes it asked for page B');

      final subscribesSent = fixture.seam.inbound
          .where((frame) => frame.contains('"handles"'))
          .length;
      final landed =
          await _within(const Duration(seconds: 2), () => fixture.client.read(_b)?.value == 22);
      print('setKeys race: subscribe answers seen $subscribesSent, '
          'B on page ${fixture.client.read(_b)}, A on page '
          '${fixture.client.read(_a)}, link ${fixture.client.linkState}, '
          'complaints ${fixture.client.complaints}');

      expect(landed, isTrue,
          reason: 'page B never populated on a healthy link: the second '
              'setKeys joined the subscribe already in flight for page A '
              '(`ResyncEngine._resubscribe` returns the in-flight future) and '
              'B\'s key set was never put on the wire. The gateway and the '
              'client agree on the sequence afterwards, so no tick rebuilds '
              'it, and the page stays blank until the next reconnect');
      expect(fixture.client.read(_a)?.value, isNull,
          reason: 'page A\'s values are still on the page the client says '
              'is page B');
    });

    test('releasing the page while its establishment is in flight lets the '
        'late snapshot repopulate a page the client no longer holds', () async {
      final fixture = await faultFixture(
        keys: const <String>{},
        seed: (plant) => plant.setValue(_a, 11),
      );
      await until('the link', () => fixture.client.isReady);

      final open = fixture.client.setKeys({_a});
      final release = fixture.client.setKeys(const <String>{});
      await Future.wait([open, release]).timeout(recovery);
      expect(fixture.client.subscribedKeys, isEmpty,
          reason: 'the client believes it holds no page');

      await Future<void>.delayed(settle);
      final shown = fixture.client.read(_a);
      print('setKeys release race: page shows $shown, keys '
          '${fixture.client.keys}, complaints ${fixture.client.complaints}');
      expect(shown, isNull,
          reason: 'a value is on the page for a subscription this client '
              'released: the first setKeys\'s subscribe landed after the '
              'release cleared the store, `ResyncEngine._establish` adopted '
              'it onto a SubscriptionState no longer in the map, and no '
              'frame will ever move it again — a released page renders its '
              'last snapshot under good quality for the rest of the shift');
    });
  });
}
