/// The fake worker claims its stamps, the way the real one does.
///
/// ## Why this file exists — a regression the Docker lane found first
///
/// `28f5cb31` (ALRM-03) made stamp provenance an **affirmative per-frame
/// claim**: `PipeFrame.substitutedStamps` names the keys whose `sourceTime`
/// the worker substituted, and a frame that states nothing (`null`) has every
/// value in it read as substituted — absence is the safe direction, and
/// `stamp_substitution_flag_test.dart` pins that rule itself. The real worker
/// (`PipeWorkerEndpoint._lastSubstituted`) was taught to make the claim;
/// `FakePlantLink` was not. So every harness-fed value — including
/// `setValue(key, v, sourceTime: plantInstant)`, which every call site means
/// as "the plant stamped this" — arrived claiming nothing, read
/// `backendReceipt`, and `resolveAlarmStamp` discarded the plant instant for
/// the injected clock. `alarm_ack_e2e_test.dart` arms 2, 4 and 5 went red on
/// exactly that, but only in the Docker lane; this file is the fast-lane pin
/// so the same slip fails in seconds instead of at the next integration run.
///
/// ## Why deriving the claim from `sourceTime` is honest HERE and nowhere else
///
/// The real worker cannot derive the claim: `translateOpcUaSample` substitutes
/// `arrivedAt`, so a substituted instant is a real, non-null `DateTime` that
/// looks exactly like a source one. Nothing on the fake's path substitutes
/// anything — a null `sourceTime` stays null all the way into the store — so
/// in `FakePlantLink`, and only there, "carries an instant" and "the source
/// stamped it" are the same fact.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../../support/harnessed_backend_state_man.dart';

/// An instant no wall clock in this suite can produce, so equality below can
/// only mean "the claim travelled", never "two clocks happened to agree".
final DateTime kPlantInstant = DateTime.utc(2024, 3, 1, 12, 0, 0, 250);

void main() {
  group('the harness claims stamp provenance the way the real worker does',
      () {
    test(
        'a sourceTime-carrying delivery reads plant through subscribeStamped, '
        'and an unstamped one reads backendReceipt', () async {
      final subject = buildHarnessedBackendStateMan();
      addTearDown(subject.shutdownFixture);

      final emissions = <StampedValue>[];
      final sub = subject.values
          .subscribeStamped(contractSpeedKey)
          .listen(emissions.add);
      addTearDown(sub.cancel);

      // "Stamped by the plant" — the exact lever alarm_ack_e2e_test.dart's
      // rig pulls when it means a plant-stamped OPC UA sample.
      subject.setValue(contractSpeedKey, 42.0, sourceTime: kPlantInstant);
      await pumpEventQueue();

      expect(emissions, isNotEmpty,
          reason: 'the delivery never reached the stamped stream at all');
      expect(emissions.last.stampSource, AlarmTsSource.plant,
          reason: 'the harness delivered an instant it meant as the plant\'s '
              'own, and the claim did not survive the pipe. This is the '
              'defect that stamped alarm_ack_e2e arms 2/4/5 from the '
              'backend\'s clock: sourceTimeIfSourced comes back null and '
              'resolveAlarmStamp discards the plant instant.');
      expect(emissions.last.sourceTimeIfSourced?.toUtc(), kPlantInstant,
          reason: 'and the instant handed to resolveAlarmStamp must be the '
              'one the fake plant stamped');

      // The other direction: a reading the fake plant did NOT stamp must not
      // acquire a plant claim by riding in the same fake.
      subject.setValue(contractSpeedKey, 43.0);
      await pumpEventQueue();

      expect(emissions.last.stampSource, AlarmTsSource.backendReceipt,
          reason: 'an unstamped delivery read as plant would be the opposite '
              'lie — the fleet-wide substitution defect ALRM-03 closed, '
              'reintroduced by the test kit');
      expect(emissions.last.sourceTimeIfSourced, isNull);
    });

    test('a resnapshot replays the claim, not just the value', () async {
      final plant = FakePlantLink('provenance');
      addTearDown(plant.dispose);

      final frames = <PipeFrame>[];
      final sub = plant.messages.listen((message) {
        if (message is PipeFrame) frames.add(message);
      });
      addTearDown(sub.cancel);

      plant.deliverAll(<String, relay.DynamicValue>{
        'stamped.key':
            relay.DynamicValue(value: 1.0, sourceTime: kPlantInstant),
        'unstamped.key': relay.DynamicValue(value: 2.0),
      });
      await pumpEventQueue();

      expect(frames, hasLength(1));
      expect(frames.single.substitutedStamps, {'unstamped.key'},
          reason: 'the delivery frame must state its claims: the stamped key '
              'affirmatively NOT substituted, the unstamped one named. A null '
              'here is "this frame states nothing", which main reads — '
              'correctly, and by pinned design — as everything substituted.');

      // Main asks again, the way it does after a worker respawn. The claim
      // must ride the replay too, or every reconnect demotes a genuine plant
      // stamp — the same defect PipeWorkerEndpoint._lastSubstituted exists to
      // prevent on the real path.
      plant.controlPort!
          .send(const PipeResnapshot(['stamped.key', 'unstamped.key']));
      await pumpEventQueue();

      expect(frames, hasLength(2),
          reason: 'the resnapshot was never answered');
      expect(frames.last.values.keys, containsAll(['stamped.key', 'unstamped.key']));
      expect(frames.last.substitutedStamps, {'unstamped.key'},
          reason: 'the replay dropped the provenance claim');
    });
  });
}
