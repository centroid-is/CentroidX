@TestOn('vm')
@Tags(['faults'])

/// Adversarial round 2 (client): a write answer nested past the sanitizer's
/// bound.
///
/// `_write` decodes its answer through `sanitize(raw)`, which throws
/// `ArgumentError` past `maxValueDepth`. That throw is inside the try, so it
/// reaches `_writeOutcomeFor` → `classifyFailure`, which rethrows every
/// `Error` on the grounds that it is a defect in this process. Here it is the
/// gateway's payload, and the promise `write` makes — an outcome as a value,
/// never an exception — is broken for a command the plant applied.
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

String _deep(int depth) => '${'[' * depth}1${']' * depth}';

MessageCorruption _deepReadback(int depth) => (message) {
      if (!message.contains('"outcome":"applied"')) return message;
      return message.replaceFirst(_readback, '"readback":${_deep(depth)}');
    };

void main() {
  test('a readback nested past maxValueDepth resolves the write, never throws',
      () async {
    final fixture = await faultFixture(
      keys: const {_key},
      corrupt: _deepReadback(maxValueDepth + 8),
      seed: (plant) => plant.setValue(_key, _before),
    );
    await until('the link', () => fixture.client.isReady);

    final cmd = newUlid();
    WriteResult? outcome;
    Object? thrown;
    try {
      outcome = await fixture.client
          .write(_key, _commanded, cmd: cmd)
          .timeout(recovery);
    } catch (error) {
      thrown = error;
    }
    print('deep readback: outcome $outcome, threw $thrown, unresolved '
        '${fixture.client.debugUnresolvedCmds}, plant attempts '
        '${fixture.served.upstreamWriteAttempts(cmd)}');

    expect(fixture.served.upstreamWriteAttempts(cmd), 1,
        reason: 'premise: the request arrived whole and the plant moved');
    expect(thrown, isNull,
        reason: 'write() threw $thrown for a command the plant applied. '
            '`sanitize` refuses a value nested past $maxValueDepth with an '
            '`ArgumentError`, the taxonomy rethrows every `Error`, and the '
            'operator gets a Dart type in a red box instead of an outcome');
    expect(outcome, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
