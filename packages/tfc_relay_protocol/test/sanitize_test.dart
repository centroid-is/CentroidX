import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('sanitize', () {
    test('replaces NaN and infinities with null and reports it', () {
      for (final poison in [double.nan, double.infinity, double.negativeInfinity]) {
        final r = sanitize(poison);
        expect(r.value, isNull);
        expect(r.hadNonFinite, isTrue);
      }
    });

    test('passes finite edge doubles through untouched', () {
      for (final ok in [
        0.0, -0.0, double.maxFinite, -double.maxFinite,
        double.minPositive, 4.9e-324, 1.5, -1.5,
      ]) {
        final r = sanitize(ok);
        expect(r.value, ok);
        expect(r.hadNonFinite, isFalse);
      }
    });

    test('walks nested lists and maps, replacing only offenders', () {
      final r = sanitize({
        'a': [1.0, double.nan, 3.0],
        'b': {'c': double.infinity, 'd': 'text'},
        'e': 42,
      });
      expect(r.hadNonFinite, isTrue);
      expect(r.value, {
        'a': [1.0, null, 3.0],
        'b': {'c': null, 'd': 'text'},
        'e': 42,
      });
    });

    test('returns the identical object when nothing needed fixing', () {
      final clean = {'a': [1.0, 2.0], 'b': 'x'};
      final r = sanitize(clean);
      expect(identical(r.value, clean), isTrue,
          reason: 'hot path must not copy clean values');
    });

    test('non-double types are untouched', () {
      for (final v in ['NaN', true, null, 7]) {
        expect(sanitize(v).value, v);
      }
    });

    test('a map that is not string-keyed keeps its key type', () {
      // WR-05. The rebuild went through cast<String, Object?>() and only ran
      // for a map that actually contained an offender, so the function
      // worked for a given shape right up until the day a weigher divided by
      // zero. The OPC UA and M2400 converters do produce int-keyed maps.
      final r = sanitize(<int, Object?>{1: double.nan, 2: 3.5});
      expect(r.hadNonFinite, isTrue);
      expect(r.value, <int, Object?>{1: null, 2: 3.5});
    });

    test('a clean non-string-keyed map is still returned identically', () {
      final clean = <int, Object?>{1: 2.5};
      expect(identical(sanitize(clean).value, clean), isTrue);
    });

    test('a structure deeper than the limit is refused, not walked', () {
      // WR-11. The decoder bounds its recursion and documents why; the
      // constructor and this walk are what the converters call on the
      // gateway, with structures the upstream controls.
      Object? deep = 1;
      for (var i = 0; i < maxValueDepth + 5; i++) {
        deep = [deep];
      }
      expect(() => sanitize(deep), throwsArgumentError);
    });

    test('a self-referential structure stops at the limit', () {
      final cycle = <Object?>[];
      cycle.add(cycle);
      expect(() => sanitize(cycle), throwsArgumentError,
          reason: 'a stack overflow on the gateway is every client\'s '
              'problem, not one tag\'s');
    });

    test('a structure at the limit still sanitizes', () {
      Object? deep = double.nan;
      for (var i = 0; i < maxValueDepth - 1; i++) {
        deep = [deep];
      }
      final r = sanitize(deep);
      expect(r.hadNonFinite, isTrue);
    });
  });

  group('WireValue', () {
    test('cannot be built in a state jsonEncode throws on', () {
      final wv = WireValue.of(double.nan);
      expect(wv.v, isNull);
      expect(wv.q, Quality.badNonFinite);
      expect(() => jsonEncode(wv.toJson()), returnsNormally);
    });

    test('non-finite forces badNonFinite even over a good quality claim', () {
      final wv = WireValue.of(double.infinity, quality: Quality.good);
      expect(wv.q, Quality.badNonFinite);
    });

    test('worse existing quality survives non-finite (worst-wins)', () {
      final wv =
          WireValue.of(double.nan, quality: Quality.errorConfig);
      expect(wv.q, Quality.errorConfig);
    });

    test('decode re-sanitizes: 1e999 arrives as Infinity and is defused', () {
      // 1e999 parses silently to double.infinity — a poison value that
      // would detonate on the next encode.
      final decoded = jsonDecode('{"v":1e999}') as Map<String, Object?>;
      final wv = WireValue.fromJson(decoded);
      expect(wv.v, isNull);
      expect(wv.q, Quality.badNonFinite);
      expect(() => jsonEncode(wv.toJson()), returnsNormally);
    });

    test('good quality and absent timestamp are omitted from JSON', () {
      expect(WireValue.of(1.5).toJson(), {'v': 1.5});
      expect(WireValue.of(1.5, quality: Quality.badStale, t: 123).toJson(),
          {'v': 1.5, 'q': Quality.badStale.code, 't': 123});
    });

    test('round-trips Icelandic strings intact', () {
      for (final s in ['Þorskflök í raspi', 'Ýsuhnakkar', 'ýmislegt æði']) {
        final json = jsonEncode(WireValue.of(s).toJson());
        final back = WireValue.fromJson(
            jsonDecode(json) as Map<String, Object?>);
        expect(back.v, s);
      }
    });

    test('fuzz: a frame of random doubles (including poisons) always encodes',
        () {
      final rng = Random(42); // seeded — failures reproduce
      final poisons = [double.nan, double.infinity, double.negativeInfinity];
      for (var run = 0; run < 200; run++) {
        final frame = <String, Object?>{};
        for (var i = 0; i < 50; i++) {
          final roll = rng.nextInt(10);
          final value = roll < 2
              ? poisons[rng.nextInt(3)]
              : (rng.nextDouble() - 0.5) * pow(10, rng.nextInt(60) - 30);
          frame['$i'] = WireValue.of(value).toJson();
        }
        expect(() => jsonEncode(frame), returnsNormally);
      }
    });
  });

  group('Quality', () {
    test('bands', () {
      expect(Quality.good.isGood, isTrue);
      expect(Quality.goodWritePending.isGood, isTrue);
      expect(Quality.uncertainLastKnown.isUncertain, isTrue);
      expect(Quality.uncertainEncoding.isUncertain, isTrue);
      expect(Quality.badStale.isBad, isTrue);
      expect(Quality.badCommFault.isBad, isTrue);
      expect(Quality.badNonFinite.isBad, isTrue);
      expect(Quality.errorConfig.isError, isTrue);
    });

    test('the two stale-ish states stay distinct', () {
      // uncertain-holding-last-known vs bad-past-deadline must never merge.
      expect(Quality.uncertainLastKnown.band,
          isNot(Quality.badStale.band));
    });

    test('every code answers exactly one band question', () {
      // CR-05. A code belonging to no band answers no to every question a
      // widget can ask, so what it renders as depends on which predicate the
      // widget happens to test first.
      for (final q in [
        Quality.good,
        Quality.goodWritePending,
        Quality.uncertainLastKnown,
        Quality.uncertainEncoding,
        Quality.uncertainUnknownCode,
        Quality.badStale,
        Quality.badCommFault,
        Quality.badNonFinite,
        Quality.errorConfig,
      ]) {
        final answers =
            [q.isGood, q.isUncertain, q.isBad, q.isError].where((b) => b);
        expect(answers, hasLength(1), reason: 'code ${q.code}');
      }
    });

    group('fromWire clamps a peer-supplied code', () {
      test('an out-of-range code reads as uncertain, not as nothing', () {
        for (final raw in [-1, 1024, 99999, -100000]) {
          final q = Quality.fromWire(raw);
          expect(q, Quality.uncertainUnknownCode, reason: 'code $raw');
          expect(q.isUncertain, isTrue,
              reason: 'a value whose trustworthiness cannot be judged must '
                  'read as untrustworthy, not as unclassifiable');
        }
      });

      test('an out-of-range code survives worst-wins composition', () {
        // The hazard the band predicates alone do not catch: a band-less
        // code can never be selected by worst(), so it composes into a
        // parent that reports good.
        expect(Quality.worst([Quality.good, Quality.fromWire(-1)]).isUncertain,
            isTrue);
      });

      test('a code that is not a number at all', () {
        expect(Quality.fromWire('bad'), Quality.uncertainUnknownCode);
        expect(Quality.fromWire(const {}), Quality.uncertainUnknownCode);
      });

      test('a non-finite code does not detonate on toInt()', () {
        // `{"q": 1e999}` decodes to Infinity, on which toInt() throws.
        final decoded = jsonDecode('{"q":1e999}') as Map<String, Object?>;
        expect(Quality.fromWire(decoded['q']), Quality.uncertainUnknownCode);
      });

      test('an absent or null code is good — quality is omitted when good',
          () {
        expect(Quality.fromWire(null), Quality.good);
      });

      test('in-band codes pass through exactly', () {
        for (final q in [
          Quality.good,
          Quality.goodWritePending,
          Quality.badStale,
          Quality.errorConfig,
          const Quality(0),
          const Quality(1023),
        ]) {
          expect(Quality.fromWire(q.code), q);
        }
      });
    });

    test('every decoder routes its quality through fromWire', () {
      // dynamic_value.dart, wire_value.dart and messages.dart each built
      // Quality straight from the wire; one that did not would reintroduce
      // the band-less value on its own path.
      expect(
          DynamicValue.fromJson(
                  {'type': 'integer', 'value': 5, 'q': -1}).quality,
          Quality.uncertainUnknownCode);
      expect(WireValue.fromJson({'v': 5, 'q': 5000}).q,
          Quality.uncertainUnknownCode);
      expect(
          UpdateParams.fromJson({
            'sub': 's',
            'seq': 1,
            't': 2,
            'q': {'7': -1}
          }).qualities[7],
          Quality.uncertainUnknownCode);
    });

    test('an explicit null quality decodes rather than throwing', () {
      // json.containsKey('q') is true for "q": null, and the old cast then
      // threw a _TypeError on the notification path.
      expect(
          DynamicValue.fromJson(
                  {'q': null, 'type': 'null', 'value': null}).quality,
          Quality.good);
      expect(WireValue.fromJson({'v': 1, 'q': null}).q, Quality.good);
    });

    test('worst-wins composition: derived values never look healthier '
        'than their worst input', () {
      expect(
        Quality.worst([Quality.good, Quality.uncertainLastKnown, Quality.good]),
        Quality.uncertainLastKnown,
      );
      expect(
        Quality.worst(
            [Quality.uncertainLastKnown, Quality.badCommFault, Quality.good]),
        Quality.badCommFault,
      );
      expect(Quality.worst([]), Quality.good);
    });

    test('worst does not discard a good-band code that is not plain good', () {
      // WR-01. Seeding the accumulator with `good` made every good-band
      // input invisible, so three call sites compared bands by hand and
      // documented why they could not use this.
      expect(Quality.worst([Quality.goodWritePending]),
          Quality.goodWritePending);
      expect(Quality.worst([Quality.goodWritePending, Quality.good]),
          Quality.goodWritePending,
          reason: 'ties break by position, and callers pass their own '
              'quality first');
      expect(Quality.worst([Quality.goodWritePending, Quality.badStale]),
          Quality.badStale,
          reason: 'a worse band still wins outright');
    });
  });
}
