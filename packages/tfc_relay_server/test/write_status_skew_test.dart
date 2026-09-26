/// `writeStatus` and a panel whose clock runs ahead.
///
/// `WriteNotReceived` is the only outcome that means **safe to re-send**, and
/// a re-send is a second command to a machine. The three checks in
/// `ValueHandlers._statusOf` exist so that verdict rests on positive evidence:
/// the id is datable, the gateway's own clock can vouch for the instant, and
/// the instant is inside the window the log still answers for.
///
/// The skew defence is deliberate and is written down at
/// `value_handlers.dart:891-906` — a command minted in a future the gateway
/// has not reached is `outcome_unwitnessed`, explicitly so a fast panel cannot
/// "buy itself a `not_received` window of `ttl + skew`".
///
/// **It holds only while the mint time is still in the future.** The entry is
/// pruned on the GATEWAY's record time (`write_outcome_log.dart:245-248`,
/// `entry.atMs < now - ttl`) and judged on the CLIENT's mint time
/// (`insideWindow(mintedAt)`). With a panel Δ ahead, `mintedAt = atMs + Δ`, so
/// the two disagree for a Δ-wide window:
///
///     pruned      : now - atMs     >  ttl
///     insideWindow: now - atMs - Δ <= ttl
///     both true for ttl < (now - atMs) <= ttl + Δ
///
/// In that window the gateway has forgotten an outcome it recorded and answers
/// `not_received` about a write the plant took. Exactly the window a panel
/// reconnecting after an outage lands in.
@Tags(['contract'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';

import 'support/ws_harness.dart';

/// Short enough that a case is seconds rather than a minute; the property is
/// about the RELATIONSHIP between the prune clock and the verdict clock, and
/// it does not depend on the size of either.
const Duration ttl = Duration(seconds: 2);

/// How far ahead the panel's clock runs. Well inside
/// `ClientConfig.implausibleClockThreshold` (5 minutes), which 04-CONTEXT
/// rules is a "warn and keep going" condition rather than a refusal — so this
/// is a panel the system says it tolerates.
const Duration skew = Duration(seconds: 1);

void main() {
  /// Writes [value] under a cmd minted at [mintedAtMs] and returns the cmd.
  Future<String> writeWithCmd(RelayFixture fixture, String key, Object? value,
      {required int mintedAtMs}) async {
    final cmd = newUlid(nowMs: mintedAtMs);
    await fixture.request(Methods.write,
        params: {'cmd': cmd, 'key': key, 'value': value},
        what: 'a write under a panel-minted cmd');
    return cmd;
  }

  Future<WriteResult> statusOf(RelayFixture fixture, String cmd) async {
    final raw = await fixture.request(Methods.writeStatus,
        params: WriteStatusParams([cmd]).toJson(),
        what: 'a writeStatus answer');
    final list = (raw as Map)['results'] as List;
    return WriteResult.fromJson((list.single as Map).cast<String, Object?>());
  }

  test(
      'a panel whose clock runs ahead is never told a write the plant took is '
      'safe to re-send', () async {
    final fixture = relayFixture(
        config: ServerConfig(tick: ServerConfig.minTick, writeOutcomeTtl: ttl));
    await fixture.ready;
    await fixture.hello();

    final key = fixture.served.keys.first;
    final ahead = DateTime.now().millisecondsSinceEpoch + skew.inMilliseconds;
    final cmd = await writeWithCmd(fixture, key, 1, mintedAtMs: ahead);

    // Immediately: the outcome is held, and the answer is the recorded fact.
    expect(await statusOf(fixture, cmd), isA<WriteApplied>(),
        reason: 'the write applied and the log is still holding its outcome');

    // Wait into the disagreement window: past the TTL measured from the
    // gateway's record time, but not past it measured from the panel's mint
    // time. This is where a reconnecting panel re-queries.
    await Future<void>.delayed(ttl + (skew ~/ 2));

    final verdict = await statusOf(fixture, cmd);
    expect(verdict, isNot(isA<WriteNotReceived>()),
        reason: 'THE PLANT TOOK THIS WRITE. `not_received` is the one answer '
            'that says a re-send is safe, and a re-send is a second command '
            'to a machine. The gateway pruned the entry on its own clock and '
            'then judged the window on the panel\'s — so it forgot an outcome '
            'it had recorded and called the forgetting evidence. Got: '
            '$verdict');
    expect(verdict.isSafeToResend, isFalse,
        reason: 'forgetting is not evidence that it never happened');
  });

  test('the same panel, with no skew, is told the honest thing', () async {
    // The control. Without skew the two clocks agree, the entry is pruned and
    // the verdict is `outcome_expired` — unknown, not safe to re-send. If this
    // case ever goes red the harness is wrong, not the property.
    final fixture = relayFixture(
        config: ServerConfig(tick: ServerConfig.minTick, writeOutcomeTtl: ttl));
    await fixture.ready;
    await fixture.hello();

    final key = fixture.served.keys.first;
    final cmd = await writeWithCmd(fixture, key, 1,
        mintedAtMs: DateTime.now().millisecondsSinceEpoch);
    await Future<void>.delayed(ttl + (skew ~/ 2));

    final verdict = await statusOf(fixture, cmd);
    expect(verdict, isA<WriteUnknown>(),
        reason: 'an outcome older than the gateway\'s memory is unknown');
    expect(verdict.isSafeToResend, isFalse);
  });

  test('a command minted in a future the gateway has not reached is unknown',
      () async {
    // The defence that IS implemented, pinned so a fix for the case above
    // cannot quietly remove it.
    final fixture = relayFixture(
        config: ServerConfig(tick: ServerConfig.minTick, writeOutcomeTtl: ttl));
    await fixture.ready;
    await fixture.hello();

    final future = DateTime.now().millisecondsSinceEpoch +
        const Duration(minutes: 4).inMilliseconds;
    final cmd = newUlid(nowMs: future);

    final verdict = await statusOf(fixture, cmd);
    expect(verdict, isA<WriteUnknown>());
    expect((verdict as WriteUnknown).reason.kind, 'outcome_unwitnessed');
    expect(verdict.isSafeToResend, isFalse);
  });
}
