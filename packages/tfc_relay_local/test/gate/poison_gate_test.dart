/// **F28 — Poison values.** The catalogue row, verbatim from
/// `f_row_registry.dart` (§7.9 via 09-PATTERNS §0):
///
/// injection: feed NaN, ±Inf, `1e999`, Latin-1 bytes from upstream
/// expectation: no frame ever fails to encode; affected key gets non-finite/encoding quality code; every other key keeps flowing
///
/// **The distinction this row rests on.** Phase 2's `MalformedPeer` injects
/// wire faults from the **peer** — its catalogue is the template for how to
/// enumerate a corruption family, not the injection site. F28 is poison
/// entering from the **plant**, through code that is ours, with `sanitize`
/// as the designed boundary: 08-05's per-tag ingest guard and 08-10's
/// per-server encoding already hold at their own layers, and this row is the
/// end-to-end sentence neither can say — one poisoned poll cycle travelling
/// upstream → ingest → store → FrameEncoder → socket → client decode, with a
/// panel on the far end still receiving everything else.
///
/// **`jsonEquals` never sees unsanitized input in this file** (STATE.md's
/// carried rule — distinct cyclic structures recurse): nothing here calls
/// it, and the struct-shaped poison is deep nesting rather than a cycle so
/// no assertion helper can wander into one either.
@TestOn('vm')
@Tags(['gate'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/error_codes.dart';

import '../support/gate_b_fixture.dart';

/// The fixture string, and it is not "test string 1" on purpose: þ/ö/í in
/// product names are the *normal case* at this plant, and an ASCII fixture
/// proves nothing about the path it is testing (§7.9 item 2).
const String icelandic = 'Þorskflök í raspi';

/// The plant's Latin-1 device family at SVN is the Saia box erector and the
/// weighers; the alias is configured `latin1` the way a deployment would
/// configure it — through `StringEncodingConfig`, 08-10's real surface.
const String latinAlias = 'BER01';
const String utfAlias = 'ST101';

/// A struct-shaped value `sanitize` refuses: nested past `maxValueDepth`
/// (64), with **int** keys so the refusal reaches the key-preserving map walk
/// (`sanitize.dart:57-63`) — a scalar never reaches that `ArgumentError`, and
/// a String-keyed struct would miss the path that once threw only "the day a
/// weigher divided by zero". Deep nesting rather than a cycle, so nothing
/// that later compares this value can recurse forever.
Object tooDeep() {
  Object deep = 0;
  for (var i = 0; i < 80; i++) {
    deep = <int, Object?>{i: deep};
  }
  return deep;
}

void main() {
  test(
      'F28a: four poison shapes in one poll cycle cost exactly their own '
      'keys — the tick encodes, the panel parses it, and the other 194 keep '
      'flowing', () async {
    final fixture = await gateBFixture(
      panels: 1,
      aliases: const [utfAlias, latinAlias],
      keysPerAlias: 100,
      encodings: const StringEncodingConfig(byAlias: {
        latinAlias: ServerStringEncoding.latin1,
      }),
    );
    final st = fixture.linkFor(utfAlias);
    final ber = fixture.linkFor(latinAlias);
    final stPage = gateBPage(utfAlias, 100);
    final berPage = gateBPage(latinAlias, 100);
    final panel = fixture.panel;

    // The four shapes. `1e999` is injected the only way it can exist — as
    // the OUTPUT of a decode: `jsonEncode` refuses to produce it
    // (malformed_peer.dart:198's reason for textual substitution), and
    // `jsonDecode('1e999')` silently answers Infinity, which is the
    // decode-side poison that enters quietly and detonates on re-encode.
    final decodePoison = jsonDecode('1e999');
    print('F28a jsonDecode(\'1e999\') = $decodePoison '
        '(${decodePoison.runtimeType})');
    expect(decodePoison, double.infinity,
        reason: 'the decode-side poison stopped being a poison, and the '
            'clause about it would be asserting nothing');

    final kNaN = stPage[0];
    final kPosInf = stPage[1];
    final kNegInf = stPage[2];
    final kDecode = stPage[3];
    final kStruct = stPage[4];
    final kLatin = berPage[0];
    final poisoned = <String>{kNaN, kPosInf, kNegInf, kDecode, kStruct, kLatin};
    final clean = <String>[
      for (final key in [...stPage, ...berPage])
        if (!poisoned.contains(key)) key,
    ];

    // Into one poll cycle — every poll cycle, because an open-circuit input
    // does not poison one sample and recover — via emitRaw and the byte seam.
    fixture.driver.overrideRaw(st, kNaN, double.nan);
    fixture.driver.overrideRaw(st, kPosInf, double.infinity);
    fixture.driver.overrideRaw(st, kNegInf, double.negativeInfinity);
    fixture.driver.overrideRaw(st, kDecode, decodePoison);
    fixture.driver.overrideRaw(st, kStruct, tooDeep());
    // Latin-1 shape: bytes that are valid multi-byte UTF-8 on a `latin1`-
    // configured alias — 08-10's misconfiguration signal, the one poison of
    // the four that carries a SUBSTITUTED payload rather than a null.
    fixture.driver.overrideBytes(ber, kLatin, utf8.encode(icelandic));

    // Every poisoned key arrives ON THE PANEL carrying its code — which is
    // also the "no frame ever fails to encode" clause doing work: a quality
    // that crossed the socket rode a tick that encoded and parsed.
    final wanted = <String, Quality>{
      kNaN: Quality.badNonFinite,
      kPosInf: Quality.badNonFinite,
      kNegInf: Quality.badNonFinite,
      kDecode: Quality.badNonFinite,
      // The depth refusal is the ingest guard's errorConfig — "waiting will
      // not fix it" (ingest.dart's refusedSampleQuality) — not a non-finite.
      kStruct: Quality.errorConfig,
      kLatin: Quality.uncertainEncoding,
    };
    await until(
      'all six poisoned keys carrying their quality codes on the panel',
      () => wanted.entries
          .every((e) => panel.client.read(e.key)?.quality == e.value),
      budget: const Duration(seconds: 10),
    );
    for (final entry in wanted.entries) {
      final seen = panel.client.read(entry.key)!;
      print('F28a poisoned ${entry.key}: quality=${seen.quality.code} '
          'value=${seen.value}');
      if (entry.key == kLatin) {
        expect(seen.value, isNot(icelandic),
            reason: 'the payload is SUBSTITUTED — the Latin-1 decode of '
                'UTF-8 bytes — under 260; the exact text under good is the '
                'good path, and it is F28b\'s, not this key\'s');
      } else {
        expect(seen.value, isNull,
            reason: '${entry.key} must carry a null payload: the last '
                'plausible number must stop rendering, because a '
                'good-looking 0 on a rate tag is a stopped belt that is not '
                'stopped');
      }
    }
    expect(st.inner.sanitizeRefusals, greaterThan(0),
        reason: 'the struct poison never reached the per-key guard — '
            'whatever refused it, it was not the boundary this row is about');

    // Every other key keeps flowing — real values, still advancing, measured
    // against the plant's own sweep count.
    final sweepsBefore = fixture.driver.sweeps;
    final before = <String, Object?>{
      for (final key in clean) key: panel.client.read(key)?.value,
    };
    await until(
      'the plant sweeping three more full cycles',
      () => fixture.driver.sweeps >= sweepsBefore + 3,
      budget: const Duration(seconds: 10),
    );
    await until(
      'all ${clean.length} clean keys advancing past their snapshot on the '
      'panel',
      () => clean.every((key) {
        final seen = panel.client.read(key);
        return seen != null &&
            seen.quality == Quality.good &&
            seen.value != before[key];
      }),
      budget: const Duration(seconds: 10),
    );
    final landed = clean
        .where((key) => panel.client.read(key)!.quality == Quality.good)
        .length;
    print('F28a clean keys landed with real values = $landed of '
        '${clean.length + poisoned.length} '
        '(sweeps $sweepsBefore -> ${fixture.driver.sweeps})');
    expect(landed, clean.length);

    // And the session is still up: nobody was evicted for the plant's sins.
    expect(fixture.sessionCount, 1,
        reason: 'the poisoned batch cost the panel its session — the exact '
            '"entire batch for every client" failure the boundary exists to '
            'prevent');
    expect(fixture.evictions, isEmpty);
    expect(fixture.gatewayComplaints, isEmpty,
        reason: 'the gateway escaped an async error while ingesting poison: '
            '${fixture.gatewayComplaints}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'F28b: the good path — the same Icelandic string on a correctly '
      'configured latin1 alias reaches the panel decoded exactly', () async {
    // Without this arm, F28a proves only that Icelandic text fails.
    final fixture = await gateBFixture(
      panels: 1,
      aliases: const [latinAlias],
      keysPerAlias: 5,
      encodings: const StringEncodingConfig(byAlias: {
        latinAlias: ServerStringEncoding.latin1,
      }),
    );
    final ber = fixture.linkFor(latinAlias);
    final key = gateBPage(latinAlias, 5).first;

    fixture.driver.overrideBytes(ber, key, latin1.encode(icelandic));
    await until(
      'the Icelandic string arriving decoded on the panel',
      () => fixture.panel.client.read(key)?.value == icelandic,
      budget: const Duration(seconds: 10),
    );
    final seen = fixture.panel.client.read(key)!;
    print('F28b decoded on the panel = "${seen.value}" '
        '(quality=${seen.quality.code})');
    expect(seen.value, icelandic,
        reason: 'character for character: a byte string that survives its '
            'own encoding is the claim, and Latin-1 maps every Icelandic '
            'letter exactly — that is the entire reason the branch exists');
    expect((seen.value as String).codeUnits, icelandic.codeUnits,
        reason: 'compared as code units so a lookalike substitution '
            '(Ð for Þ, a combining accent) cannot pass a string == that '
            'some normalisation forgave');
    expect(seen.quality, Quality.good);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'F28c: an error naming a poisoned value still encodes, and every '
      'subsequent error path on that peer still answers', () async {
    // Nothing in the tree proves this from the upstream direction today:
    // MalformedPeer proved the 02-05 hang at the channel layer, and
    // session_hello_test proves it against a RelaySession over an in-memory
    // pair — this arm is the composed gateway over a REAL socket, with the
    // plant already poisoned, which is the state an operator's panel is
    // actually in when the error arrives.
    final fixture = await gateBFixture(
      panels: 1,
      aliases: const [utfAlias],
      keysPerAlias: 5,
    );
    final st = fixture.linkFor(utfAlias);
    final page = gateBPage(utfAlias, 5);

    // Poison a key first: the peer about to err is serving a plant that is
    // already carrying non-finite input.
    fixture.driver.overrideRaw(st, page.first, double.infinity);
    await until(
      'the poisoned key reading badNonFinite on the panel',
      () =>
          fixture.panel.client.read(page.first)?.quality ==
          Quality.badNonFinite,
      budget: const Duration(seconds: 10),
    );

    // A raw textual peer, because a request carrying `1e999` cannot be built
    // by any Dart encoder — jsonEncode refuses to emit Infinity — which is
    // also exactly how such a request arrives from a non-Dart client.
    final ws = await WebSocket.connect('ws://127.0.0.1:${fixture.port}');
    addTearDown(() => ws.close());
    final frames = <Map<String, Object?>>[];
    final sub = ws.listen((frame) {
      if (frame is String) {
        frames.add((jsonDecode(frame) as Map).cast<String, Object?>());
      }
    });
    addTearDown(sub.cancel);

    Map<String, Object?>? answerFor(String id) {
      for (final frame in frames) {
        if (frame['id'] == id) return frame;
      }
      return null;
    }

    // Error one: a hello whose params hold Infinity after decode. The typed
    // decode throws, and the thrown reason INTERPOLATES what it met — the
    // error is ABOUT the poisoned value. Pre-02-05, echoing the request into
    // error.data made this exact answer unencodable, silently discarded, and
    // the caller waited forever.
    ws.add('{"jsonrpc":"2.0","id":"poison-1","method":"hello",'
        '"params":{"protocol":1e999,"supported":[],"client":{"name":"p",'
        '"version":"1"}}}');
    await until(
      'the FIRST error frame answering the poisoned request',
      () => answerFor('poison-1') != null,
      budget: const Duration(seconds: 3),
    );
    final first =
        (answerFor('poison-1')!['error'] as Map).cast<String, Object?>();
    print('F28c first error: code=${first['code']} '
        'message="${first['message']}"');
    expect(first['code'], ServerErrorCodes.typeMismatch);
    expect((first['data'] as Map)['request'], contains('omitted'),
        reason: 'the pre-substituted data.request (02-05\'s pattern) is what '
            'keeps this answer sendable — the raw request holds Infinity and '
            'echoing it is what makes the error itself unencodable');

    // Error two, same peer: the clause that matters. A peer whose first
    // error was silently discarded has ALL its error paths wedged; a peer
    // that answered is proven to still be answering.
    ws.add('{"jsonrpc":"2.0","id":"poison-2","method":"hello",'
        '"params":{"protocol":1e999,"supported":[],"client":{"name":"p",'
        '"version":"1"}}}');
    await until(
      'the SECOND error on the same peer still answering',
      () => answerFor('poison-2') != null,
      budget: const Duration(seconds: 3),
    );
    final second =
        (answerFor('poison-2')!['error'] as Map).cast<String, Object?>();
    print('F28c second error: code=${second['code']}');
    expect(second['code'], ServerErrorCodes.typeMismatch);

    // The plant session two doors down never noticed: its keys keep
    // flowing while the raw peer errs.
    final valueAt = fixture.panel.client.read(page.last)?.value;
    await until(
      'the panel\'s clean keys still advancing after both errors',
      () => fixture.panel.client.read(page.last)?.value != valueAt,
      budget: const Duration(seconds: 10),
    );
    expect(fixture.evictions, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
