@TestOn('vm')
@Tags(['faults'])

/// Adversarial round 2 (client): the one write answer that is not sanitized.
///
/// 16-04 S8 made `write` decode its answer through `sanitize(raw)`, so an
/// `1e999` in it becomes null rather than `Infinity`. The `writeStatus`
/// re-query that resolves an unknown write after a reconnect decodes each
/// entry straight out of `_asJson(entry)` (`_answerFor`), and `_settle`
/// adopts the `readback` onto the page under `Quality.good` through the same
/// `_adoptReadback` the write path uses. A readback of `1e999` decodes to
/// `double.infinity` and lands on the mimic as a good reading.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';

import 'support/fault_fixture.dart';
import 'support/gate_bands.dart';

const String _key = scenarioKey;
const int _before = 1200;
const int _commanded = 1500;

final RegExp _readback = RegExp(r'"readback":-?[0-9][0-9.eE+-]*');

MessageCorruption _poisonWriteStatusReadback(String literal) => (message) {
      if (!message.contains('"results"')) return message;
      return message.replaceAll(_readback, '"readback":$literal');
    };

void main() {
  test(
      'pin: a writeStatus answer\'s non-finite readback does not land on the '
      'page as a good reading', () async {
    final fixture = await faultFixture(
      keys: const {_key},
      withProxy: true,
      corrupt: _poisonWriteStatusReadback('1e999'),
      seed: (plant) => plant.setValue(_key, _before),
    );
    await until('the link', () => fixture.client.isReady);

    // The answer to the write is withheld, so the outcome is unknown and the
    // command stays re-queryable.
    fixture.proxy.bufferServerToClient = true;
    final cmd = newUlid();
    final outcome =
        await fixture.client.write(_key, _commanded, cmd: cmd).timeout(recovery);
    expect(outcome, isA<WriteUnknown>(),
        reason: 'premise: the withheld answer must leave the write unknown');
    expect(fixture.client.debugUnresolvedCmds, contains(cmd));

    // Release the withheld bytes, then end the connection so the next `ready`
    // re-queries the command through `writeStatus`.
    fixture.proxy.bufferServerToClient = false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    fixture.proxy.killOnce();
    await until('the re-query to be answered',
        () => fixture.client.debugWriteStatusAnswers.isNotEmpty,
        budget: recovery);
    await Future<void>.delayed(settle);

    final answer = fixture.client.debugWriteStatusAnswers.last;
    final shown = fixture.client.read(_key);
    print('writeStatus readback: answer $answer readback '
        '${answer is WriteApplied ? answer.readback : '-'}, page $shown '
        'value ${shown?.value} quality ${shown?.quality}, node '
        '${fixture.client.listen(_key).value}, keys ${fixture.client.keys}, '
        'link ${fixture.client.linkState}, ready ${fixture.client.isReady}, '
        'complaints ${fixture.client.complaints}, last results frame '
        '${fixture.seam.lastMatching((m) => m.contains('"results"'))}');

    expect(
        fixture.seam.inbound.any((frame) => frame.contains('"readback":1e999')),
        isTrue,
        reason: 'premise: no inbound frame carried the poisoned readback, so '
            'the client decoded a well-formed answer');
    expect(answer, isA<WriteApplied>(),
        reason: 'premise: the gateway resolved the command as applied');

    final value = shown?.value;
    expect(value is double && !value.isFinite, isFalse,
        reason: 'the page holds $value under ${shown?.quality}. `writeStatus` '
            'answers are decoded without `sanitize`, so `1e999` became '
            '`double.infinity`, and `_settle` adopted it onto the tag as a '
            'good reading — the exact substitution S8 closed on the `write` '
            'path. A mimic now renders Infinity with the badge that says it '
            'can be acted on');
    expect(shown?.quality, isNot(Quality.good),
        reason: 'a readback the gateway spelled as 1e999 is on the page '
            'under good quality');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
