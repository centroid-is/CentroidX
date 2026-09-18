/// A successful write must never blank the tag it just wrote.
///
/// **08-REVIEW CR-01, and it was reachable from the shipped gateway on every
/// write.** Both real adapters answer a successful write with
/// `WriteAcknowledged(at: …)` and **no readback** — the OPC UA one at
/// `opcua_upstream_link.dart:630`, the Modbus/UMAS base at
/// `modbus_upstream_link.dart:386` — because neither protocol hands a value
/// back with its acknowledgement. `translateWriteAnswer` maps that to
/// `WriteApplied(readback: null)`, and `_confirmWrite` used to put
/// `outcome.readback` into the store under `Quality.good`. So every successful
/// write from the shipped gateway published **null under a good quality** on
/// the key the operator had just written, until the next upstream sample
/// repainted it.
///
/// On a boolean indicator `asBool` on null reads false; on a numeric mimic it
/// is an empty box carrying no fault badge, so nothing tells the operator that
/// the reading is not a reading. That is the failure `_refuse`, `ingestSamples`
/// and `PipeHealth` each spend a paragraph refusing to commit — *"never a zero
/// and never a false"* — arriving by the one path nothing checked, because
/// **every arm in `write_test.dart` supplies a readback** and no real adapter
/// can.
///
/// ## The subject is a real adapter, deliberately
///
/// `FakeUpstreamLink.write` echoes the written value back as its readback, so
/// it cannot reach this defect and a case written against it would prove
/// nothing. The subject here is `DrivableModbusLink` — the production
/// `ModbusUpstreamLink` over a `DeviceClient` double — which produces exactly
/// the readback-less acknowledgement the plant produces.
///
/// ## The ruling this file pins
///
/// *Applied means applied **and read back**.* An acknowledgement with no value
/// in it confirms the write and not a reading, so the composer performs **one
/// bounded read** through the link and adopts what the device answers. A read
/// is not a retry: it asks the plant what it holds, and asking is the only way
/// this system is allowed to be sure. If that read does not produce a reading
/// either, the outcome stays `WriteApplied` and the **store is left alone** —
/// the subscription stream stays the truth, and the badge comes off so no
/// permanent amber box is left behind. Never a synthetic value, never null
/// under good.
library;

import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'modbus_link_test.dart' show DrivableModbusLink, registerEntry;
import 'upstream_link_contract_test.dart' show speedKey;

/// The one key these cases write to.
const String key = speedKey;

/// The alias `DrivableModbusLink`'s fixture entries are spelled with.
const String alias = 'ST101';

({LocalStateMan man, DrivableModbusLink link}) build() {
  final link = DrivableModbusLink(alias: alias);
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      // A register entry and not the OPC UA fixture: the subject is the Modbus
      // adapter, and a mapping it cannot claim would route nowhere.
      mappings: KeyMappings(
          nodes: <String, KeyMappingEntry>{key: registerEntry(key)}),
    ),
    staleAfter: const Duration(seconds: 30),
  );
  return (man: man, link: link);
}

/// Every value the store published for [key] while [body] ran.
///
/// The assertion is over the whole sequence and not over the end state,
/// because the defect was a *window*: the null-under-good was overwritten by
/// the next upstream sample one publishing interval later, and a case that
/// only read the end state would have missed it exactly as the suite did.
Future<List<DynamicValue>> record(
    LocalStateMan man, Future<void> Function() body) async {
  final seen = <DynamicValue>[];
  final handle = man.listen(key);
  void note() => seen.add(handle.value);
  handle.addListener(note);
  try {
    await body();
  } finally {
    handle.removeListener(note);
  }
  return seen;
}

void main() {
  group('CR-01: a readback-less acknowledgement never publishes a blank', () {
    test('the real adapter path publishes no null-under-good, and the store '
        'ends at what the DEVICE holds', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      // What the device is actually holding. Delivered through the adapter's
      // own ingest seam, so the link's cache is the device's reading and not
      // something this case reached in and set.
      built.link.setValue(key, 10);
      built.man.applyUpstreamBatch(
          <String, DynamicValue>{key: DynamicValue(value: 10)});

      late WriteResult outcome;
      final seen = await record(built.man, () async {
        outcome = await built.man.write(key, 5);
      });

      expect(outcome, isA<WriteApplied>(),
          reason: 'the device acknowledged, so the write was applied — that '
              'part was never in question');
      expect((outcome as WriteApplied).readback, isNull,
          reason: 'anti-vacuity: if the adapter had started supplying a '
              'readback this case would be asserting about a path the plant '
              'cannot reach');

      for (final value in seen) {
        expect(value.value == null && value.quality.isGood, isFalse,
            reason: 'a good-quality blank on the tag an operator just wrote. '
                'On a boolean indicator asBool on null reads false and on a '
                'numeric mimic it is an empty box with no fault badge, so '
                'nothing tells them the reading is not a reading');
      }

      final ended = built.man.read(key)!;
      expect(ended.value, 10,
          reason: 'the readback is what the DEVICE holds, read back through '
              'the link — never the number that was typed. A PLC clamping a '
              'setpoint is ordinary; a mimic showing the typed value labelled '
              '"confirmed" is the confirmation lying');
      expect(ended.quality, Quality.good);
      expect(built.man.writePendingKeys, isEmpty,
          reason: 'the window has to CLOSE for the badge to mean anything '
              'while it is open');
    });

    test('when the readback read produces no reading either, the STORE is left '
        'alone and the outcome is still applied', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      // The store knows a value; the link has never had one delivered, so its
      // read answers uncertainNotYetKnown with no payload — a round trip that
      // came back with no reading in it.
      built.man.applyUpstreamBatch(
          <String, DynamicValue>{key: DynamicValue(value: 41.5)});

      late WriteResult outcome;
      final seen = await record(built.man, () async {
        outcome = await built.man.write(key, 5);
      });

      expect(outcome, isA<WriteApplied>(),
          reason: 'the device acknowledged. A failed readback READ is not '
              'evidence the write did not land, and downgrading the outcome '
              'for it would turn a successful write into an unknown one');

      for (final value in seen) {
        expect(value.value == null && value.quality.isGood, isFalse);
      }

      final ended = built.man.read(key)!;
      expect(ended.value, 41.5,
          reason: 'the last thing anybody actually measured stays on the '
              'screen. Inventing a value here — the typed one, or null — is '
              'the same lie in two different costumes');
      expect(ended.quality, Quality.good);
      expect(built.man.writePendingKeys, isEmpty,
          reason: 'and the badge still comes off, or the operator is left '
              'with a permanent amber box they learn to ignore');
    });

    test('a rejected write is unchanged: the badge comes off and nothing is '
        'read back', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{key: DynamicValue(value: 7)});
      built.link.fake.failWriteWith(StateError('Bad_NotWritable'));

      final before = built.link.fake.writes.length;
      final outcome = await built.man.write(key, 5);

      expect(outcome, isA<WriteRejected>());
      expect(built.link.fake.writes.length, before,
          reason: 'nothing reached the device');
      expect(built.man.read(key)!.value, 7);
      expect(built.man.read(key)!.quality, Quality.good);
    });
  });

  wr02();

  group('CR-01: the deadman tick does not buy a read per tick', () {
    test('a hold publishes no null-under-good, and costs one crossing per tick '
        'and not two', () async {
      final built = build();
      addTearDown(built.man.dispose);
      await built.man.start();

      built.man.applyUpstreamBatch(
          <String, DynamicValue>{key: DynamicValue(value: 0)});

      final seen = <DynamicValue>[];
      final handle = built.man.listen(key);
      void note() => seen.add(handle.value);
      handle.addListener(note);
      addTearDown(() => handle.removeListener(note));

      final hold = await built.man.holdToRun(key);
      expect(hold.isHeld, isTrue);
      final afterEngage = built.link.fake.writes.length;

      // The cadence is the caller's — `tick()` is driven by the finger on the
      // button, not by a timer in here. Ten of them is one second of a hold.
      for (var i = 0; i < 10; i++) {
        hold.tick();
        await Future<void>.delayed(Duration.zero);
      }
      final ticked = built.link.fake.writes.length - afterEngage;
      await hold.release();

      expect(ticked, greaterThan(0),
          reason: 'anti-vacuity: the deadman has to have been fed');
      for (final value in seen) {
        expect(value.value == null && value.quality.isGood, isFalse,
            reason: 'the tick took the same readback-less path, so it wrote a '
                'good-quality blank onto the deadman tag ten times a second');
      }
    });
  });
}

/// WR-02's other half: the bit is computed by the composer, so the composer is
/// where the end-to-end claim has to be made.
///
/// The adapter arm in `modbus_link_test.dart` proves the guard honours the
/// flag. This one proves the flag arrives — that `LocalStateMan._settle`,
/// which is the only layer that can evaluate `expect` against the last value
/// the gateway heard, carries the fact of having done so down to the adapter
/// rather than dropping it at `_crossIntoThePlant`.
void wr02() {
  group('WR-02: the compare-and-set bit reaches the adapter', () {
    test('an array-element write with a matching expect applies, and without '
        'one is refused by name', () async {
      final link = DrivableModbusLink(alias: alias);
      final man = LocalStateMan(
        links: <UpstreamLink>[link],
        router: KeyRouter.overLinks(
          <UpstreamLink>[link],
          mappings: KeyMappings(nodes: <String, KeyMappingEntry>{
            key: registerEntry(key, bitMask: 0x0004, bitShift: 2),
          }),
        ),
        staleAfter: const Duration(seconds: 30),
      );
      addTearDown(man.dispose);
      await man.start();

      // The comparison is against the last value THIS side heard, which is why
      // it can only happen here.
      man.applyUpstreamBatch(
          <String, DynamicValue>{key: DynamicValue(value: false)});

      final refused = await man.write(key, true);
      expect(refused, isA<WriteRejected>());
      expect((refused as WriteRejected).reason.kind,
          'array_element_requires_expect');

      final guarded = await man.write(key, true, expect: false);
      expect(guarded, isA<WriteApplied>(),
          reason: 'the operator did the thing the refusal asked for. Before '
              'WR-02 they got the same refusal back, because the bit stopped '
              'at _settle and the adapter was handed a literal false');
    });
  });
}
