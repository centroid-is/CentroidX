/// One poisoned tag costs one tag.
///
/// This is the Phase 1 handoff, carried through every phase since as a standing
/// constraint and reaching, here, the first code able to break it: **sanitize
/// failure = ONE TAG fails, never a poll cycle.** `sanitize` throws
/// `ArgumentError` on depth > 64 or a cycle
/// (`packages/tfc_relay_protocol/lib/src/sanitize.dart:33-39`), the same bound
/// `DynamicValue`'s constructor enforces (`dynamic_value.dart:609-619`), and a
/// struct-heavy TwinCAT tag is exactly where a depth-64 structure appears.
///
/// The payloads come off [FakeUpstreamLink.rawEmissions], which 08-03 built for
/// this: `emitRaw` records the payload **unsanitized**, so the gateway's own
/// converter is pointed at what the wire produced rather than at
/// `DynamicValue`'s own output — a converter tested against its own output
/// proves only that it is consistent with itself.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// A structure past `maxValueDepth`. A drive struct nested inside a line struct
/// inside a batch struct is three deep; this is what a converter with a bad
/// recursion looks like, or a PLC type that references itself.
Object? tooDeep() {
  Object? value = 1;
  for (var i = 0; i < 70; i++) {
    value = <Object?>[value];
  }
  return value;
}

/// A self-referential list. The same wall stops it, which is what keeps it from
/// being a stack overflow — and a stack overflow on the gateway is every
/// client's problem rather than one tag's.
Object? cyclic() {
  final list = <Object?>[];
  list.add(list);
  return list;
}

({LocalStateMan man, FakeUpstreamLink link}) build(Iterable<String> keys) {
  final link = FakeUpstreamLink(alias: st101Alias, keys: keys);
  final man = LocalStateMan(
    links: [link],
    router: KeyRouter.overLinks(
      [link],
      mappings: keyMappingsOf(keys, alias: st101Alias),
    ),
    staleAfter: const Duration(minutes: 5),
  );
  return (man: man, link: link);
}

void main() {
  group('a value sanitize refuses costs exactly that tag', () {
    test('the poisoned key goes bad with a NULL value and the other three land',
        () async {
      const keys = ['A.one', 'A.poison', 'A.two', 'A.three'];
      final built = build(keys);
      final man = built.man;
      final link = built.link;
      await man.start();
      addTearDown(man.dispose);

      link
        ..emitRaw('A.one', 1)
        ..emitRaw('A.poison', tooDeep())
        ..emitRaw('A.two', 2)
        ..emitRaw('A.three', 3);

      final outcome = man.ingestRaw(link.rawEmissions);

      expect(outcome.refusals.keys, ['A.poison']);
      expect(man.read('A.poison')!.value, isNull,
          reason: 'never a last plausible number under a good quality');
      expect(man.read('A.poison')!.quality, Quality.errorConfig,
          reason: 'a shape this converter cannot represent is not transient — '
              'waiting will not fix it, which is what errorConfig means');

      // Asserted explicitly, and this is the arm that matters: a case that only
      // read the poisoned key would pass against an implementation that
      // dropped the whole batch and happened to retry it.
      expect(man.read('A.one')!.value, 1);
      expect(man.read('A.two')!.value, 2);
      expect(man.read('A.three')!.value, 3);
      expect(man.read('A.one')!.quality, Quality.good);
    });

    test('a CYCLE is refused the same way as a depth', () async {
      const keys = ['A.loop', 'A.fine'];
      final built = build(keys);
      final man = built.man;
      await man.start();
      addTearDown(man.dispose);

      built.link
        ..emitRaw('A.loop', cyclic())
        ..emitRaw('A.fine', 'ok');
      man.ingestRaw(built.link.rawEmissions);

      expect(man.read('A.loop')!.quality, Quality.errorConfig);
      expect(man.read('A.fine')!.value, 'ok');
    });

    test('at the size of a real poll cycle: one poison, 429 land with their '
        'exact values', () async {
      final keys = <String>[
        for (var i = 0; i < 429; i++) 'Line$i.Motor1',
        'Line429.Poison',
      ];
      final built = build(keys);
      final man = built.man;
      await man.start();
      addTearDown(man.dispose);

      for (var i = 0; i < 429; i++) {
        built.link.emitRaw('Line$i.Motor1', i);
      }
      built.link.emitRaw('Line429.Poison', tooDeep());

      final outcome = man.ingestRaw(built.link.rawEmissions);

      final lost = <String>[
        for (var i = 0; i < 429; i++)
          if (man.read('Line$i.Motor1')?.value != i) 'Line$i.Motor1',
      ];
      expect(lost, isEmpty,
          reason: 'one typo-shaped struct must not cost 429 other tags. '
              '${lost.length} were lost');
      expect(outcome.refusals, hasLength(1));
      expect(outcome.batch, hasLength(430),
          reason: 'every key asked about gets an entry, including the refused '
              'one — a missing entry is a blank where a fault belongs');
    });

    test('the refusal is logged once per key, not once per sample', () async {
      const keys = ['A.poison'];
      final built = build(keys);
      final man = built.man;
      await man.start();
      addTearDown(man.dispose);

      for (var i = 0; i < 20; i++) {
        man.ingestRaw([(key: 'A.poison', raw: tooDeep())]);
      }

      expect(man.ingestLog.refusals, 20,
          reason: 'every refusal is counted — the number is a diagnostic');
      expect(man.ingestLog.logged, 1,
          reason: 'but a struct that fails at 10 Hz would write the log file '
              'in an afternoon, and the second line says nothing the first one '
              'did not');
      expect(man.ingestLog.refusedKeys, {'A.poison'});
    });
  });

  group('the wire hazards land as qualities rather than as exceptions', () {
    late LocalStateMan man;

    setUp(() async {
      man = build(const ['A.rate', 'A.level']).man;
      await man.start();
      addTearDown(man.dispose);
    });

    test('a non-finite value lands with badNonFinite and a null payload', () {
      // An open-circuit 4-20 mA input, or a divide-by-zero in a weigher rate.
      man.ingestRaw([
        (key: 'A.rate', raw: double.infinity),
        (key: 'A.level', raw: 12.5),
      ]);

      expect(man.read('A.rate')!.quality, Quality.badNonFinite);
      expect(man.read('A.rate')!.value, isNull,
          reason: 'jsonEncode throws on NaN and Infinity, so the alternative '
              'to a null here is one open-circuit input failing the batch for '
              'every connected client');
      expect(man.read('A.level')!.value, 12.5);
    });

    test('worst-wins is the library\'s composition, not a hand-rolled one', () {
      man.ingestRaw(
        [(key: 'A.rate', raw: double.nan)],
        quality: Quality.uncertainLastKnown,
      );
      expect(man.read('A.rate')!.quality, Quality.badNonFinite,
          reason: 'bad beats uncertain, and the comparison is '
              'DynamicValue\'s own mint through Quality.worst '
              '(dynamic_value.dart:643-648). Nothing here re-implements it');
    });

    test('one batch, one pass: only the keys that CHANGED notify', () {
      var rate = 0;
      var level = 0;
      final rateHandle = man.listen('A.rate');
      final levelHandle = man.listen('A.level');
      void countRate() => rate++;
      void countLevel() => level++;
      rateHandle.addListener(countRate);
      levelHandle.addListener(countLevel);
      addTearDown(() {
        rateHandle.removeListener(countRate);
        levelHandle.removeListener(countLevel);
      });

      man.ingestRaw([(key: 'A.rate', raw: 1), (key: 'A.level', raw: 2)]);
      expect([rate, level], [1, 1]);

      // The same batch again: nothing moved, so nobody rebuilds. This is the
      // k-of-n property, and it only holds because the batch goes through
      // ValueStore.applyBatch rather than a loop of single sets.
      man.ingestRaw([(key: 'A.rate', raw: 1), (key: 'A.level', raw: 2)]);
      expect([rate, level], [1, 1]);

      man.ingestRaw([(key: 'A.rate', raw: 9), (key: 'A.level', raw: 2)]);
      expect([rate, level], [2, 1],
          reason: 'one of the two moved; one of the two pages rebuilds');
    });
  });

  group('IN-02: landed counts the batch, not the arithmetic', () {
    test('a key repeated in one cycle — refused then good — is counted as '
        'landed once, not as refused', () {
      // The batch is keyed by name, so the second sample overwrites the first
      // and the map holds ONE entry. `refusals` still holds the key from the
      // earlier attempt, and `batch.length - refusals.length` then counted a
      // key that landed as one that did not — reaching zero, or below it on a
      // cycle with several such keys.
      final outcome = ingestSamples(<RawSample>[
        (key: 'ST101.CN01.MOT01.speed', raw: _cyclic()),
        (key: 'ST101.CN01.MOT01.speed', raw: 41.5),
      ]);

      expect(outcome.batch, hasLength(1));
      expect(outcome.refusals, isEmpty,
          reason: 'the surviving entry is good, so nothing in this batch is '
              'being published as refused. The THROW is not forgotten — '
              'IngestLog has it, and that is where a converter bug is '
              'diagnosed from');
      expect(outcome.landed, 1,
          reason: 'the surviving entry converted cleanly and is what every '
              'subscriber will read. The number is described as evidence '
              'somebody reads, so it has to be about the batch rather than '
              'about two lengths that describe different things');
      expect(outcome.batch.values.single.value, 41.5);
    });

    test('and it never goes negative, which is what the subtraction could do',
        () {
      final outcome = ingestSamples(<RawSample>[
        for (var i = 0; i < 3; i++) (key: 'one.key', raw: _cyclic()),
        (key: 'one.key', raw: 1),
      ]);
      expect(outcome.landed, greaterThanOrEqualTo(0));
      expect(outcome.landed, 1);
    });
  });
}

/// A self-referential structure — what `sanitize` refuses, and the cheapest
/// way to make one key fail without inventing a converter.
Object _cyclic() {
  final list = <Object?>[];
  list.add(list);
  return list;
}
