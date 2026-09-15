/// Decoding a `subscribe` result — against wire text, because every trap here
/// was observed rather than imagined.
///
/// Source: 04-RESEARCH Finding 7, recorded from a live subscribe against
/// `relayFixture()`. The result carries `[sub, epoch, seq, handles, meta,
/// snapshot]`; `handles` is `{PIPE.connected: 1, …}`; `snapshot` and `meta`
/// are keyed by **handle as a JSON string**; and `rejected` comes back
/// **absent**, not `{}`.
///
/// Every fixture below is a JSON *string* run through `jsonDecode`, never a
/// hand-built Dart map. That is the whole point: a hand-built
/// `{1: {'v': true}}` has int keys and a hand-built `double.infinity` is
/// visibly infinite, so a decoder written against Dart literals passes a suite
/// that never contains the two things that actually arrive — string keys and
/// `1e999`, which `jsonDecode` turns into `Infinity` in silence.
///
/// What breaks in the plant without this: STATE.md records that Phase 1's
/// defect cluster was the decode boundary — 5 of 5 Criticals. None of these
/// failures crash. A snapshot filed under the string `"1"` leaves every tag on
/// the page reading "not yet known" forever while the socket looks healthy; an
/// absent `rejected` map taken as a `Map` blanks a page over one hand-typed
/// key; and an `Infinity` that reaches the cache renders as a plausible
/// number under good quality and detonates on the next encode.
library;

import 'dart:convert';

import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// Finding 7's observed result, transcribed as the wire text that produced it.
const _findingSeven = '''
{
  "sub": "page1",
  "epoch": "01M004KDBH4MQHBRN4525RXYGD",
  "seq": 0,
  "handles": {"PIPE.connected": 1, "PIPE.rtt_ms": 2, "PIPE.data_age_ms": 3},
  "meta": {"1": {"typeId": "bool"}, "2": {"typeId": "int"},
           "3": {"typeId": "int"}},
  "snapshot": {"1": {"v": true}, "2": {"v": 0}, "3": {"v": 0}},
  "rejected": null
}
''';

/// Builds a result around [body], so a case can vary one field and inherit a
/// shape that is known to be the real one.
String _resultWith(String body) => '''
{
  "sub": "page1",
  "epoch": "01M004KDBH4MQHBRN4525RXYGD",
  "seq": 0,
  "handles": {"PIPE.connected": 1, "PIPE.rtt_ms": 2},
  $body
}
''';

void main() {
  group('decodeSubscribeResult', () {
    test('the Finding 7 result decodes verbatim', () {
      final decoded = decodeSubscribeResult(jsonDecode(_findingSeven));

      expect(decoded.sub, 'page1',
          reason: 'an update names its subscription by this string; get it '
              'wrong and every frame for the page is dropped as unknown');
      expect(decoded.epoch, '01M004KDBH4MQHBRN4525RXYGD',
          reason: 'the epoch is what tells a stale frame from a live one');
      expect(decoded.seq, 0,
          reason: 'a fresh snapshot starts the delta chain at zero; a wrong '
              'baseline reads as a permanent gap and resyncs forever');
      expect(decoded.values, hasLength(3),
          reason: 'all three PIPE tags were in the snapshot, so all three '
              'must reach the page');
    });

    test('handle-keyed snapshot entries map through handles to real tag names',
        () {
      final decoded = decodeSubscribeResult(jsonDecode(_findingSeven));

      expect(decoded.values['PIPE.connected']?.value, isTrue,
          reason: 'the health badge reads this tag; filed under any other '
              'name it stays "not yet known" while the link is up');
      expect(decoded.values['PIPE.rtt_ms']?.value, 0);
      expect(decoded.values.keys, isNot(contains('1')),
          reason: 'the snapshot\'s JSON string key is a handle, not a tag '
              'name — a decoder that used it raw would cache every value '
              'under a name no widget ever asks for');
      expect(decoded.handles[1], 'PIPE.connected',
          reason: 'the handle map is inverted for the update path, which '
              'sees handles and must answer with keys');
    });

    test('an int-keyed snapshot decodes the same as a string-keyed one', () {
      // Not every peer's decoder produces string keys; the protocol package's
      // own `_intKeyed` tolerates both, and so must this one.
      final decoded = decodeSubscribeResult({
        'sub': 'page1',
        'epoch': 'E1',
        'seq': 0,
        'handles': {'PIPE.connected': 1},
        'snapshot': {1: {'v': true}},
      });

      expect(decoded.values['PIPE.connected']?.value, isTrue,
          reason: 'the key type a peer chose must not decide whether the '
              'operator sees a value');
    });

    test('a snapshot key with no matching handle is dropped with a complaint',
        () {
      final decoded = decodeSubscribeResult(
          jsonDecode(_resultWith('"snapshot": {"1": {"v": true}, '
              '"9": {"v": 42}}')));

      expect(decoded.values, hasLength(1),
          reason: 'handle 9 was never announced, so there is no tag name to '
              'file it under — guessing one puts a number on a mimic under a '
              'label the server never agreed to');
      expect(decoded.values['PIPE.connected']?.value, isTrue,
          reason: 'the entries that do map through must still arrive: one '
              'unmapped handle costs one tag, never the page');
      expect(decoded.complaints, isNotEmpty,
          reason: 'silently dropping a value the server sent is how a page '
              'goes half-blank with nothing in the log to explain it');
      expect(decoded.complaints.join(' '), contains('9'),
          reason: 'the complaint names the handle, or it cannot be chased');
    });

    test('an absent rejected map is not a crash', () {
      // Finding 7: the live server omits `rejected` entirely rather than
      // sending `{}`.
      final decoded = decodeSubscribeResult(
          jsonDecode(_resultWith('"snapshot": {"1": {"v": true}}')));

      expect(decoded.rejected, isEmpty,
          reason: 'nothing was rejected, and a page must not fail to open '
              'because the good case is expressed by omission');
      expect(decoded.values['PIPE.connected']?.value, isTrue,
          reason: 'the values still arrive on the ordinary path');
    });

    test('a null rejected and an empty rejected both mean no rejections', () {
      for (final literal in ['null', '{}']) {
        final decoded = decodeSubscribeResult(jsonDecode(
            _resultWith('"snapshot": {"1": {"v": true}}, '
                '"rejected": $literal')));
        expect(decoded.rejected, isEmpty,
            reason: 'rejected: $literal means the same thing as absent, and '
                'a page that opens must not depend on which one a server '
                'version chose');
      }
    });

    test('a populated rejected is recorded per key and the call still succeeds',
        () {
      final decoded = decodeSubscribeResult(jsonDecode(
          _resultWith('"snapshot": {"1": {"v": true}}, '
              '"rejected": {"PIPE.typo": {"kind": "unknownKey", '
              '"message": "no such key"}}')));

      expect(decoded.rejected.keys, ['PIPE.typo'],
          reason: 'a page config carries ~1500 hand-edited keys; one typo '
              'costs that one tag and is reported, never thrown');
      expect(decoded.rejected['PIPE.typo']?.kind, 'unknownKey',
          reason: 'the kind is what the client branches on');
      expect(decoded.values['PIPE.connected']?.value, isTrue,
          reason: 'the other 1499 keys still open the page');
    });

    test('a 1e999 snapshot value decodes to null carrying badNonFinite', () {
      final decoded = decodeSubscribeResult(
          jsonDecode(_resultWith('"snapshot": {"1": {"v": 1e999}}')));

      final value = decoded.values['PIPE.connected'];
      expect(value, isNotNull);
      expect(value!.value, isNull,
          reason: 'jsonDecode turns 1e999 into Infinity without a word, and '
              'an Infinity in the cache detonates the next jsonEncode — '
              'failing the whole batch for every client');
      expect(value.quality, Quality.badNonFinite,
          reason: 'a null of good quality reads as an absent value; the '
              'operator must see that the number was bad, not missing');
    });

    test('a quality code outside the four-band model is clamped, not '
        'range-checked by hand', () {
      final decoded = decodeSubscribeResult(jsonDecode(
          _resultWith('"snapshot": {"1": {"v": true, "q": 9999}}')));

      expect(decoded.values['PIPE.connected']?.quality,
          Quality.uncertainUnknownCode,
          reason: 'a code from no band must not read as good; a '
              'version-skewed peer would otherwise get its unknown states '
              'believed');
    });

    test('a result that is not a JSON object throws FormatException naming '
        'what it got', () {
      expect(
          () => decodeSubscribeResult(jsonDecode('[1, 2, 3]')),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('List'))),
          reason: 'a peer that answers with a list is lying about the '
              'protocol, and the honest outcome is a decode failure that '
              'says so — not a half-built subscription');
    });
  });

  group('SubscriptionState', () {
    test('carries subId, keys, epoch, lastSeq, handles and generation', () {
      final state = SubscriptionState(
          subId: 'page1', keys: {'PIPE.connected', 'PIPE.rtt_ms'});

      expect(state.subId, 'page1');
      expect(state.keys, {'PIPE.connected', 'PIPE.rtt_ms'},
          reason: 'the requested key set is what a resubscribe re-sends; '
              'lose it and the page comes back empty after a reconnect');
      expect(state.lastSeq, isNull,
          reason: 'no delta has been applied yet, and a baseline of zero '
              'would make the first real frame look like a replay');
      expect(state.handles, isEmpty);
      expect(state.generation, 0,
          reason: 'no gateway mints generation zero, so an update frame that '
              'arrives before any snapshot cannot match one');
    });

    test('adopts a decoded subscribe result', () {
      final state = SubscriptionState(subId: 'page1', keys: {'PIPE.connected'});
      state.adopt(decodeSubscribeResult(jsonDecode(_findingSeven)));

      expect(state.epoch, '01M004KDBH4MQHBRN4525RXYGD');
      expect(state.lastSeq, 0,
          reason: 'the snapshot is the baseline the delta chain counts from');
      expect(state.handles[1], 'PIPE.connected');
      expect(state.generation, 0,
          reason: 'this fixture is the live capture from 04-RESEARCH Finding '
              '7, taken before the gateway minted generations: absent decodes '
              'as zero, which is what every frame from such a gateway carries '
              'too, so the comparison passes instead of dropping the stream');
    });
  });
}
