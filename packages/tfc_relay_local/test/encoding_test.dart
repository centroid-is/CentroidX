/// Per-server string encoding: Þorskflök í raspi, and the quality code that
/// makes a failed decode visible.
///
/// The failure this file exists to stop is **not** a crash. It is
/// `utf8.decode(bytes, allowMalformed: true)`, which is what every decode path
/// in this stack does today — `extensions.dart:416`, `m2400.dart:135`,
/// `umas_types.dart:870-880` — and which turns a Latin-1 `þ` into U+FFFD and
/// keeps going, under a good quality, with nothing in any log. Silent mojibake
/// on a product name is worse than an exception, because an exception gets
/// somebody's attention.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jbtm/jbtm.dart'
    show
        M2400Field,
        M2400RecordType,
        M2400StubServer,
        parseM2400Frame;
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings, M2400NodeConfig;
import 'package:tfc_dart/core/umas_types.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// The string that has to survive. A real SVN product name, and every letter in
/// it that is not ASCII — Þ, ö, í — lives inside Latin-1.
const String icelandic = 'Þorskflök í raspi';

/// The same string as the bytes a Latin-1 device puts on the wire.
final Uint8List latin1Bytes = Uint8List.fromList(latin1.encode(icelandic));

/// The plant's two aliases in this file: a weigher configured Latin-1, and a
/// TwinCAT PLC left on the default.
const String weigher = 'weigher1v';
const String twincat = 'ST101';

void main() {
  wr01();
  wr10();
  group('the configuration is per server alias', () {
    test('an unconfigured alias is utf8, which is what the stack does today',
        () {
      const config = StringEncodingConfig();

      expect(config.encodingFor(twincat), ServerStringEncoding.utf8);
    });

    test('a configured alias is what it was configured as', () {
      const config = StringEncodingConfig(byAlias: {
        weigher: ServerStringEncoding.latin1,
      });

      expect(config.encodingFor(weigher), ServerStringEncoding.latin1);
      expect(config.encodingFor(twincat), ServerStringEncoding.utf8,
          reason: 'per SERVER. One Latin-1 weigher does not make the TwinCAT '
              'PLC beside it Latin-1, and a global switch is how the wrong '
              'half of a plant gets mojibake instead of the right half getting '
              'fixed');
    });

    test('the alias match is EXACTLY as strict as every other one', () {
      // Measured, not assumed: `StateManConfig.normalizeAlias`
      // (state_man.dart:454-455) maps empty to null and nothing else — it does
      // not fold case and does not trim. This case pins that the encoding table
      // is as strict as the rest of the gateway rather than more lenient. A
      // table that quietly matched `Weigher1V` against `weigher1v` would be a
      // second opinion about what an alias is, and the two opinions would
      // disagree on the day somebody renamed a server.
      const config = StringEncodingConfig(byAlias: {
        'Weigher1V': ServerStringEncoding.latin1,
      });

      expect(config.encodingFor('Weigher1V'), ServerStringEncoding.latin1);
      expect(config.encodingFor('weigher1v'), ServerStringEncoding.utf8,
          reason: 'a near-miss falls back to the default, which is the safe '
              'direction: the operator sees mojibake AND a 260, rather than a '
              'Latin-1 read of a UTF-8 server that looks plausible');
    });

    test('the unnamed server is addressable, because normalizeAlias makes '
        'empty and unnamed the same thing', () {
      const config = StringEncodingConfig(byAlias: {
        '': ServerStringEncoding.latin1,
      });

      expect(config.encodingFor(''), ServerStringEncoding.latin1);
    });
  });

  group('Þorskflök í raspi', () {
    test('survives a Latin-1 device, character for character', () {
      final decoded = decodePlantString(latin1Bytes,
          encoding: ServerStringEncoding.latin1);

      expect(decoded.text, icelandic,
          reason: 'every Icelandic letter lives inside Latin-1, so latin1 is '
              'EXACT here where allowMalformed is lossy — '
              'tfc_mcp_server/lib/src/parser/source_encoding.dart:20-24 is the '
              'one place in this repository that already got this right');
      expect(decoded.quality, Quality.good);
    });

    test('under the utf8 default it mojibakes AND says so', () {
      final decoded =
          decodePlantString(latin1Bytes, encoding: ServerStringEncoding.utf8);

      expect(decoded.text, isNot(icelandic));
      expect(decoded.text, contains('\u{FFFD}'),
          reason: 'this is exactly what ships today — the replacement '
              'characters are not the news');
      expect(decoded.quality, Quality.uncertainEncoding,
          reason: 'THE quality code is the news. 260 has been defined and '
              'unreferenced in production since Phase 0 waiting for this: the '
              'failure becomes visible instead of silent, which is the whole '
              'point. Today it is mojibake under a GOOD quality');
      expect(decoded.quality.code, 260);
    });

    test('a valid UTF-8 string under the default is untouched and good', () {
      // The anti-vacuity arm. Without it, a `decodePlantString` that returned
      // `uncertainEncoding` unconditionally would pass every case above.
      final decoded = decodePlantString(utf8.encode(icelandic),
          encoding: ServerStringEncoding.utf8);

      expect(decoded.text, icelandic);
      expect(decoded.quality, Quality.good);
    });

    test('plain ASCII is good under both encodings', () {
      for (final encoding in ServerStringEncoding.values) {
        expect(decodePlantString(utf8.encode('CN01 running'), encoding: encoding),
            (text: 'CN01 running', quality: Quality.good));
      }
    });

    test('latin1 can never itself fail', () {
      // All 256 byte values map, so the fallback cannot throw. A file that is
      // neither encoding degrades to mojibake rather than being dropped —
      // the same bargain source_encoding.dart strikes.
      // 1..255: byte 0 is the S7 terminator and is stripped before the
      // decoder ever runs, which the padding group below is about.
      final decoded = decodePlantString(
          Uint8List.fromList(List<int>.generate(255, (i) => i + 1)),
          encoding: ServerStringEncoding.latin1);

      expect(decoded.text.runes.length, 255);
      expect(decoded.quality, Quality.good);
    });
  });

  group('S7 NUL padding', () {
    test('is stripped, and the text before it is kept whole', () {
      final padded = Uint8List.fromList(
          [...latin1.encode(icelandic), 0, 0, 0, 0, 0, 0]);

      final decoded =
          decodePlantString(padded, encoding: ServerStringEncoding.latin1);

      expect(decoded.text, icelandic,
          reason: 'an S7 STRING is a fixed-width buffer; the padding is not '
              'part of the product name and would render as boxes');
    });

    test('a buffer that is all padding is the empty string, not a fault', () {
      final decoded = decodePlantString(Uint8List.fromList([0, 0, 0, 0]),
          encoding: ServerStringEncoding.latin1);

      expect(decoded.text, isEmpty);
      expect(decoded.quality, Quality.good,
          reason: 'an empty tag is an empty tag, not a decode failure');
    });

    test('bytes AFTER the first NUL are not smuggled through', () {
      final decoded = decodePlantString(
          Uint8List.fromList([...latin1.encode('ok'), 0, 0x41, 0x42]),
          encoding: ServerStringEncoding.latin1);

      expect(decoded.text, 'ok');
    });
  });

  group('the value, not just the string', () {
    test('carries the quality onto the DynamicValue', () {
      final at = DateTime.utc(2026, 9, 1, 12);

      final value = decodePlantStringValue(latin1Bytes,
          encoding: ServerStringEncoding.utf8, sourceTime: at);

      expect(value.quality, Quality.uncertainEncoding);
      expect(value.sourceTime, at);
      expect(value.value, isNotNull,
          reason: 'unlike a comms fault, a decode fallback still has a '
              'reading — a mangled one, openly labelled. Blanking it would '
              'throw away the only information there is');
    });

    test('a Latin-1 string round-trips through sanitize and jsonEncode', () {
      final value = decodePlantStringValue(latin1Bytes,
          encoding: ServerStringEncoding.latin1,
          sourceTime: DateTime.utc(2026, 9, 1));

      final sanitized = sanitize(value.value);
      expect(sanitized.value, icelandic);

      // A test that stops before the encoder has not proven the operator sees
      // it. Icelandic characters are not the wire hazard NaN is, but the claim
      // is that the string reaches a panel, and the panel is on the other side
      // of jsonEncode.
      final encoded = jsonEncode({'v': sanitized.value});
      expect(jsonDecode(encoded), {'v': icelandic});
    });
  });

  group('the two foreign packages took an additive parameter', () {
    test('jbtm decodes with utf8 + allowMalformed by DEFAULT, unchanged', () {
      final frame = Uint8List.fromList(
          [...latin1.encode('(14\tFLD\t$icelandic')]);

      final record = parseM2400Frame(frame)!;

      expect(record.fields['FLD'], isNot(icelandic),
          reason: 'the default must reproduce today\'s behaviour BYTE FOR '
              'BYTE. jbtm ships to the plant through the app long before it '
              'reaches it through this gateway (T-08-38)');
      expect(record.fields['FLD'], contains('\u{FFFD}'));
    });

    test('jbtm decodes Latin-1 exactly when handed this package\'s decoder',
        () {
      final frame = Uint8List.fromList(
          [...latin1.encode('(14\tFLD\t$icelandic')]);

      final record = parseM2400Frame(frame,
          decodeBytes: latin1DecoderFor(ServerStringEncoding.latin1))!;

      expect(record.fields['FLD'], icelandic);
    });

    test('umas_types decodes with utf8 + allowMalformed by DEFAULT, unchanged',
        () {
      final bytes = Uint8List.fromList([...latin1.encode('ök'), 0, 0]);
      final type = UmasDataTypeRef(id: 1, name: 'STRING', byteSize: bytes.length);

      final parsed = parseVariableValue(bytes, 0, type);

      expect(parsed.value, isNot('ök'));
      expect((parsed.value as String), contains('\u{FFFD}'));
    });

    test('umas_types decodes Latin-1 when handed the decoder, NUL trim kept',
        () {
      final bytes = Uint8List.fromList([...latin1.encode('ök'), 0, 0x41]);
      final type = UmasDataTypeRef(id: 1, name: 'STRING', byteSize: bytes.length);

      final parsed = parseVariableValue(bytes, 0, type,
          decodeString: latin1DecoderFor(ServerStringEncoding.latin1));

      expect(parsed.value, 'ök',
          reason: 'the NUL-position trimming that was already there is '
              'untouched — the byte after the terminator is not smuggled in');
    });
  });
}

/// WR-10: `good` on the `latin1` branch means "without loss", not "correct" —
/// and the one case where this side can tell the difference cheaply.
void wr10() {
  group('WR-10: a latin1 alias fed UTF-8 says so', () {
    test('a UTF-8 buffer on a latin1 alias is uncertainEncoding, and the text '
        'is still the configured decode', () {
      // What a TwinCAT server sends for `Þorskflök` — and what a weigher
      // wrongly configured as latin1 would then render as `ÃžorskflÃ¶k`,
      // silently, under a good quality.
      final bytes = utf8.encode('Þorskflök');
      final decoded =
          decodePlantString(bytes, encoding: ServerStringEncoding.latin1);

      expect(decoded.quality, Quality.uncertainEncoding,
          reason: 'latin1 maps all 256 byte values, so it decoded without '
              'loss — but "without loss" is not "correctly", and a buffer that '
              'is also valid multi-byte UTF-8 is strong evidence somebody '
              'typed the wrong encoding into a per-alias config field');
      expect(decoded.text, isNot('Þorskflök'),
          reason: 'and the text is the CONFIGURED decode: the config says '
              'which encoding this server speaks, and this function flags a '
              'doubt rather than overruling it');
    });

    test('pure ASCII on a latin1 alias is good, which is the false positive '
        'that would have made the signal useless', () {
      final decoded = decodePlantString(utf8.encode('COD FILLET 5KG'),
          encoding: ServerStringEncoding.latin1);
      expect(decoded.quality, Quality.good,
          reason: 'ASCII is valid in both encodings and says nothing about '
              'either. A quality code that fired on every ordinary product '
              'name is a quality code an operator learns to ignore');
    });

    test('genuine Latin-1 is good — an accented letter is not a UTF-8 '
        'sequence', () {
      final decoded = decodePlantString(latin1.encode('Þorskflök'),
          encoding: ServerStringEncoding.latin1);
      expect(decoded.quality, Quality.good);
      expect(decoded.text, 'Þorskflök',
          reason: 'the whole reason this branch exists: every Icelandic '
              'letter lives inside Latin-1, so this is exact where '
              'allowMalformed is lossy');
    });
  });
}

/// WR-01: the wire between the mechanism and the plant.
///
/// **What 08-10 shipped was a mechanism plus its unit tests, with the wire
/// between them missing.** `decodePlantString`, `latin1DecoderFor` and
/// `Quality.uncertainEncoding` had no caller anywhere in `lib/`;
/// `GatewayConfig.stringEncodings` built a table nothing read;
/// `buildUpstreamLink` constructed the weigher and the Modbus clients passing
/// no decoder at all. So a deployment that wrote `"string_encoding": "latin1"`
/// got the value parsed, validated, echoed back in `toJson` — and
/// `utf8.decode(…, allowMalformed: true)` at every actual decode, which is the
/// behaviour the module exists to replace. 08-10's threat register recorded
/// T-08-37 as "Mitigated", which overstated what shipped.
///
/// So this group is deliberately **not** pointed at the helper. It runs bytes
/// through a real socket into a link built by `buildUpstreamLink` from a real
/// `UpstreamLinkConfig`, which is the path a plant takes, and the only thing
/// it varies is the config field.
void wr01() {
  group('WR-01: string_encoding reaches the decode through a real adapter', () {
    late M2400StubServer server;

    setUp(() async {
      server = M2400StubServer();
      await server.start();
    });

    tearDown(() async => server.shutdown());

    /// A STAT record whose product name is encoded in [encoding], framed as
    /// the device frames it. `sendRawGarbage` is the stub's raw-bytes door —
    /// its named helpers all encode UTF-8, which is the thing under test.
    List<int> statFrame(String material, Encoding encoding) => <int>[
          0x02,
          ...encoding.encode('(${M2400RecordType.recStat.id}\t'
              '${M2400Field.weight.id}\t12.37\t'
              '${M2400Field.material.id}\t$material'),
          0x03,
        ];

    Future<DynamicValue> firstMaterial(
        UpstreamLink link, String key, KeyMappings mappings) async {
      final ref = link.resolve(key, mappings.nodes[key]!)!;
      final seen = link.subscribe(ref).first;
      // The record has to land after the subscription, or the weigher's
      // event-only stream has nobody listening when it arrives.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      server.sendRawGarbage(statFrame('Þorskflök', latin1));
      return seen.timeout(const Duration(seconds: 5));
    }

    const String key = 'weigher1v.material';
    const String alias = 'weigher1v';
    final mappings = KeyMappings(nodes: <String, KeyMappingEntry>{
      key: KeyMappingEntry(
        m2400Node: M2400NodeConfig(
          recordType: M2400RecordType.recStat,
          field: M2400Field.material,
          serverAlias: alias,
        ),
      ),
    });

    test('latin1 in the config means latin1 at the decode — the Icelandic '
        'letters arrive intact', () async {
      final link = await buildUpstreamLink(
        UpstreamLinkConfig(
          alias: alias,
          protocol: UpstreamProtocol.m2400,
          endpoint: '127.0.0.1:${server.port}',
          stringEncoding: ServerStringEncoding.latin1,
        ),
        mappings: mappings,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: const Duration(seconds: 5));

      final value = await firstMaterial(link, key, mappings);

      expect(value.value, 'Þorskflök',
          reason: 'every Icelandic letter lives inside Latin-1, so this is '
              'EXACT where allowMalformed is lossy. Before WR-01 the config '
              'field was parsed, validated and echoed, and this decode was '
              'still utf8 with allowMalformed');
    });

    test('and the default is unchanged: the same bytes on a utf8 alias are '
        'the mojibake this module exists to make visible', () async {
      final link = await buildUpstreamLink(
        UpstreamLinkConfig(
          alias: alias,
          protocol: UpstreamProtocol.m2400,
          endpoint: '127.0.0.1:${server.port}',
          // Not passed at all: the default, which is what every deployment
          // that has not thought about encodings gets.
        ),
        mappings: mappings,
      );
      addTearDown(link.dispose);
      await link.connect(deadline: const Duration(seconds: 5));

      final value = await firstMaterial(link, key, mappings);

      expect(value.value, isNot('Þorskflök'),
          reason: 'the contrast is the evidence: same bytes, same code path, '
              'one config field different. If both branches produced the same '
              'text this case would be asserting that the decoder does '
              'nothing');
      expect(value.value.toString(), contains('\u{FFFD}'),
          reason: 'and this is what shipped everywhere before ruling 10: a '
              'replacement character on a packing-hall screen, under a good '
              'quality, with nothing in any log');
    });
  });
}
