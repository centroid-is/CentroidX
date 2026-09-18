/// The harness's own sabotage: cut the channel, and the same checks must fail.
///
/// `channel_subscribe_contract_test.dart` reports five green cases. On its own
/// that says nothing about the channel — a factory that quietly handed back a
/// plain `FakeStateMan` would report exactly the same five, and so would one
/// whose client kept a reference to the served source and answered from it.
/// Both are easy mistakes and neither has a symptom. This file is what makes
/// the green mean something: sever the channel, and four of those five cases
/// must go red.
///
/// The sabotage is a *silence*, not a close. `ChannelPair.sever` drops
/// server → client messages on the floor and leaves client → server flowing, so
/// the served source still applies every lever it is sent and simply never
/// answers. That is the fault this project exists to make visible — the link
/// looks up, requests keep going out, the page keeps rendering its last numbers
/// — and it is strictly harder to detect than a closed socket, which arrives as
/// an event a client could notice.
///
/// Two rules the assertions follow, both from `lib/src/meta.dart:60-79`. The
/// failure must arrive *inside a budget*, because a severed channel produces no
/// event at all and a check that waited for one would hang for the runner's
/// thirty seconds and then name this file instead of the property. And the
/// sabotage must be *surgical*: the last case, which never needed a value to
/// arrive, still passes. A cut that broke everything would prove nothing about
/// any individual property — the same argument `broken_write.dart:19-23`
/// already makes about the deliberately damaged implementations.
@Tags(['meta'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// Bounds the whole file. A severed channel must fail fast — that is the
/// property — so the file's own runtime is evidence, and this number is what
/// stops a regression from being absorbed by the runner timeout.
const _fileBudget = Duration(seconds: 10);

void main() {
  final wall = Stopwatch()..start();

  group('with the channel severed, the subscribe contract fails by name', () {
    test('a subscribed key delivers its current value, good', () async {
      await _expectSevered(checkListenDeliversCurrentValue,
          reason: 'the first value a page shows never arrived and the check '
              'passed anyway, so the harness is reading a value that did not '
              'come over the channel');
    });

    test('a listener is notified of every change after it attaches', () async {
      await _expectSevered(checkListenDeliversSubsequentChanges,
          reason: 'a subscription that delivers nothing was judged sound. This '
              'is the failure operators cannot see — a page of numbers, none '
              'of which has moved — and it is the first thing the suite is '
              'required to catch');
    });

    test('the subscribe() stream mirrors listen() and serves every listener',
        () async {
      await _expectSevered(checkSubscribeStreamMirrorsListen,
          reason: 'the stream adapter produced values with nothing feeding it, '
              'so ported stream-consuming widgets would be served from '
              'somewhere other than the pipe');
    });

    test('an unknown key reports a configuration error instead of throwing',
        () async {
      await _expectSevered(checkUnknownKeyReportsConfigErrorNotThrow,
          reason: 'the case reached its assertions without the batch it waits '
              'for ever arriving, which means its barrier is not a barrier');
    });
  });

  group('the cut is surgical', () {
    test('a disposed source notifies nobody — still passes', () async {
      // Deliberately the one case that never needed a value to arrive: it
      // disposes and then asserts an absence. If severing the channel broke
      // this too, the sabotage would be proving that a dead harness fails
      // everything, which is a fact about the sabotage and not about any of
      // the four properties above.
      final api = _severedChannelSource();
      addTearDown(api.dispose);
      await checkDisposeStopsNotifications(api);
    });

    test('the same cases pass with the channel intact', () async {
      // The control arm. Without it, a harness that was broken for some other
      // reason — a factory that returns something disposed, a served source
      // that never starts — would make every assertion above pass for the
      // wrong reason.
      final api = channelServedFake();
      addTearDown(api.dispose);
      await checkListenDeliversCurrentValue(api);
    });
  });

  test('the whole bite costs less than its budget', () {
    print('the channel bite-proof ran in ${wall.elapsed.inMilliseconds} ms '
        '(budget ${_fileBudget.inSeconds} s)');
    expect(wall.elapsed, lessThan(_fileBudget),
        reason: 'a severed channel must fail every check inside its own '
            'deadline. If this file starts costing seconds, a check has '
            'stopped wrapping its awaits and is being failed by the runner '
            'timeout instead — which reports a file name rather than the '
            'property an operator lost');
  });
}

/// A channel-served source whose channel is cut before anything crosses it.
///
/// Severed synchronously, before the opening snapshot's microtask runs, so not
/// even the values the source already held reach the client.
StateManApi _severedChannelSource() {
  final harness = serveFakeOverChannel();
  harness.channel.sever();
  return harness.api;
}

/// Runs [check] against a severed source and asserts it reports the violation.
///
/// [expectContractViolation] holds it to all three clauses: it must not hang,
/// it must not pass, and it must report through `expect`/`fail` so the message
/// names the property rather than a stack frame. The budget is deliberately far
/// tighter than the two-second default — every await inside these cases is
/// wrapped in a 200 ms `within`, so a violation that takes longer than this is
/// one that escaped a deadline.
Future<void> _expectSevered(
  Check<StateManApi> check, {
  required String reason,
}) async {
  final api = _severedChannelSource();
  addTearDown(api.dispose);
  try {
    await expectContractViolation(check, api,
        budget: const Duration(milliseconds: 800));
  } on TestFailure catch (failure) {
    fail('$reason\n\n${failure.message}');
  }
}
