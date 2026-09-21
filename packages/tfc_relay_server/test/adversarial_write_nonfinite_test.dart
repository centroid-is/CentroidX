@TestOn('vm')

/// Adversarial: the ingress sanitizer defeats the write path's own refusal
/// of non-finite numbers.
///
/// `RelaySession._defuse` decodes every inbound frame, runs `sanitize` over it
/// and — when anything was non-finite — **re-encodes the sanitized tree**, so
/// the `Peer` and every handler behind it see `null` where the wire carried
/// `1e999`. `ValueHandlers.write` then checks `sanitized.hadNonFinite` on a
/// tree that has already been cleaned, finds nothing, and proceeds:
///
///  * `expect: 1e999` arrives as `expect: null`, which is this path's encoding
///    of "no compare-and-set guard" — the guarded write the operator sent is
///    applied unconditionally;
///  * `value: 1e999` arrives as `value: null`, and `null` is written to the
///    tag — "actuating the device with something nobody chose", in the
///    handler's own words.
///
/// Both are the exact outcomes `value_handlers.dart:383-398` and
/// `WriteParams.fromJson` say must never happen, and both are reachable by
/// any peer past the handshake. The unit kit in `value_handlers_test.dart`
/// cannot see it because it hands the handler an un-defused map.
@Tags(['ws'])
library;

import 'dart:convert';

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/ws_harness.dart';

const _key = 'CN01.MOT01.speed';

/// Waits until a frame answering [id] has arrived, or the budget runs out.
Future<Map<String, Object?>?> _answerFor(RelayFixture fixture, String id,
    {Duration budget = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    for (final frame in fixture.inbound) {
      final decoded = jsonDecode(frame);
      if (decoded is Map && decoded['id'] == id) {
        return decoded.cast<String, Object?>();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return null;
}

void main() {
  test('a write whose expect guard is 1e999 is refused before the plant, '
      'not applied unconditionally', () async {
    final fixture = relayFixture();
    await fixture.ready;
    await fixture.hello();
    fixture.served.setValue(_key, 1200);

    final cmd = newUlid();
    // Written as text: there is no way to reach 1e999 through jsonEncode.
    // The guard says "only if it still reads 999" — which it does not — so a
    // correct gateway either refuses the frame or the guard fails. Neither
    // path may move the tag.
    fixture.client.sink.add('{"jsonrpc":"2.0","id":"guarded",'
        '"method":"${Methods.write}","params":{"cmd":"$cmd","key":"$_key",'
        '"value":1450,"expect":1e999}}');

    final answer = await _answerFor(fixture, 'guarded');
    expect(answer, isNotNull, reason: 'the write was never answered');
    final error = answer!['error'];
    expect(error, isA<Map>(),
        reason: 'a write carrying a non-finite expect must be refused as a '
            'shape error (value_handlers.dart:383-398). It was answered '
            '${answer['result']} instead — the ingress _defuse nulled the '
            'guard before the handler could see it, and a guarded write '
            'became an unconditional one');
    expect((error as Map)['code'], rpc_error.INVALID_PARAMS);
    expect(fixture.served.upstreamWriteAttempts(cmd), 0,
        reason: 'INVALID_PARAMS means definitively no effect');
    expect(fixture.served.read(_key)?.value, 1200,
        reason: 'the tag moved under a guard that was never checked');
  });

  test('a write whose value is 1e999 is refused, not written as null',
      () async {
    final fixture = relayFixture();
    await fixture.ready;
    await fixture.hello();
    fixture.served.setValue(_key, 1200);

    final cmd = newUlid();
    fixture.client.sink.add('{"jsonrpc":"2.0","id":"poison-value",'
        '"method":"${Methods.write}","params":{"cmd":"$cmd","key":"$_key",'
        '"value":1e999}}');

    final answer = await _answerFor(fixture, 'poison-value');
    expect(answer, isNotNull, reason: 'the write was never answered');
    expect(answer!['error'], isA<Map>(),
        reason: 'a write carrying a non-finite value must be refused; it '
            'was answered ${answer['result']} — the ingress _defuse turned '
            'the value into null and the gateway actuated the device with '
            'something nobody chose');
    expect(fixture.served.upstreamWriteAttempts(cmd), 0,
        reason: 'nothing may be sent for a write the handler cannot read');
    expect(fixture.served.read(_key)?.value, 1200,
        reason: 'null landed on the tag');
  });
}
