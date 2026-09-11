/// F6: a write is in flight and the link is cut *inside a frame*.
///
/// **F6 — Drop during in-flight write.** `subscribe, then cutMidFrame() on the
/// write request`. The catalogue asks that the write completes with an
/// **unknown** outcome surfaced to the caller; never auto-retried (rule 3);
/// reconnect does NOT replay it.
///
/// **What separates this row from F7, which is next door.** F7's arms kill the
/// connection with an RST (`killOnce`) or swallow it whole (`blackhole`): the
/// frames that were delivered were delivered, and the ones that were not are
/// simply absent. This row's injection is different in kind — the connection is
/// ended with a **FIN after exactly n bytes**, so the peer's decoder is handed a
/// *partial frame* and has to reject it without desynchronising or inventing a
/// value. That is the failure mode `write_in_flight_gate_test.dart:11-18` says
/// its own four arms cannot produce, which is why F6 kept a `missing` entry
/// until this file existed.
///
/// **The direction the lever actually cuts, which is not the one the catalogue
/// names.** `cutMidFrame` arms the **server→client** line only, deliberately and
/// with the reason recorded at `fault_proxy.dart:973-977`: a cut counted across
/// both directions would fire on the client's own request bytes and end the
/// connection before the response existed. So the partial frame this row
/// delivers reaches the **client's** decoder, not the gateway's, and no lever in
/// this repository can truncate the client→server direction. The consequence is
/// recorded as a deviation in `f_row_registry.dart` rather than papered over,
/// and it makes the case *sharper* rather than weaker — see the next paragraph.
///
/// **The asymmetry this case exists to assert.** Because the request arrives
/// whole, the gateway decodes it and the plant genuinely moves. The answer is
/// what gets truncated. So the caller is left with `unknown` about a write that
/// **did happen**, which is the dangerous direction: a client that resolved its
/// own uncertainty by re-sending would stroke a ram the operator commanded once
/// a second time. The case therefore asserts both halves — the caller's verdict
/// is `unknown`, and the plant's own attempt counter is exactly 1 and stays 1
/// across the recovery. The gap between what the caller can know and what the
/// plant did is the row.
///
/// **Why `n` is measured rather than chosen.** A hard-coded byte count stops
/// cutting mid-frame the moment a field is added to the response, and a case
/// that has quietly stopped truncating anything still passes every assertion
/// about the caller's verdict — the link would simply die a little later. So the
/// frame length is measured off `seam.inbound` on a control write and the cut is
/// placed strictly inside it, which is what makes "a *partial* frame reached the
/// decoder" true by construction rather than by hope.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:io' show Platform;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

void main() {
  group('F6 — a frame truncated on the wire under a write', () {
    // **Skipped on Windows: the lever cannot promise this case's setup.**
    //
    // `cutMidFrame(n)` spends a byte budget on the next n bytes travelling
    // server->client, whatever they belong to. This case needs those bytes to
    // be the write's *answer* — it measured the response frame at 125 b and
    // cuts at 62 b — but the gateway's tick engine puts a frame on the same
    // line every 100 ms, and `ServerConfig` validates `tick` into a
    // 50-100 ms band (`server_config.dart:420-423`), so it cannot be slowed
    // out of the way. When a tick spends the budget first the link dies before
    // the request is sent, the plant records **0** attempts, and the assertion
    // at the heart of this row — "the request arrived whole, only the answer
    // was truncated" — fails on a case that never got set up.
    //
    // `write_readback_freshness_test.dart` was skipped for this a commit
    // earlier, and its comment claimed THIS file was safe because it "asserts
    // only that the outcome is WriteUnknown". That was wrong: line 138 asserts
    // `upstreamWriteAttempts == 1` exactly as S3 does. It had not failed yet,
    // which on a race is not the same as being immune, and the Windows agent
    // has since produced it.
    //
    // Not a deletion: the row is measured on macOS and Linux every run, and
    // the property is not platform-specific. The durable fix is a lever that
    // can cut a *named* frame rather than a byte count.
    test('F6: a write frame truncated on the wire resolves unknown, and the '
        'ram does not stroke twice', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      final transitions = <LinkState>[];
      final watching = fixture.client.linkStates.listen(transitions.add);
      addTearDown(watching.cancel);

      // **The control write, which does three jobs at once.** It measures the
      // frame the cut is placed inside; it proves the page was live and the
      // write path healthy *before* the fault (the second anti-vacuity arm);
      // and it establishes that a write under this fixture ordinarily comes
      // back `applied`, so the `unknown` below is the cut talking.
      final controlCmd = newUlid();
      final control = await fixture.client
          .write(scenarioKey, 1500, cmd: controlCmd)
          .timeout(recovery);
      expect(control, isA<WriteApplied>(),
          reason: 'the control write came back $control on an unfaulted link, '
              'so the page was not live and everything below would be '
              'measuring a broken fixture rather than a cut');

      final frameLength = fixture.seam.inbound
          .firstWhere((frame) => frame.contains(controlCmd),
              orElse: () => fail('no inbound frame mentions the control '
                  'command, so there is nothing to measure the cut against '
                  'and `n` would be a magic number'))
          .length;
      // Strictly inside one frame: whatever frame is crossing when the budget
      // runs out is delivered in part. Half is arbitrary only in the sense that
      // any fraction would do — what matters is that it is *derived from the
      // measurement* and therefore cannot drift above a whole frame when the
      // payload changes shape.
      final n = frameLength ~/ 2;
      print('F6: measured response frame $frameLength b, cutting at $n b');

      final sentBefore = fixture.client.debugWritesSent;
      final cmd = newUlid();

      // The catalogue's own injection, through the proxy's setter — which is
      // the only supported route. **Never reach into `DelayLine`'s raw
      // byte-countdown field**: it is a getter/setter pair, the proxy has to
      // fan the arm out to every live pair and hang the FIN callback off it,
      // and a writer that reached past all that would arm nothing and silently
      // test an uncut link (Phase 2 handoff, 07-RESEARCH trap 4). The
      // acceptance sweep greps this directory for that field name, so the
      // token is deliberately not written here.
      fixture.proxy.cutMidFrame(n);
      final pending = fixture.client.write(scenarioKey, 1700, cmd: cmd);

      final outcome = await pending.timeout(recovery);
      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome. The link was cut inside a '
              'frame while the answer was on its way, so nobody can know '
              'whether the plant took it — and "unknown" is the only verdict '
              'that leaves the operator free to go and look');
      expect(fixture.client.debugWritesSent - sentBefore, 1,
          reason: 'the write reached the wire '
              '${fixture.client.debugWritesSent - sentBefore} times. More than '
              'once is a second stroke of a ram the operator commanded once');

      // **The first anti-vacuity arm: the cut landed on something.** Asserted
      // as the transport death it caused rather than as "the setter was
      // called" — a lever that armed nothing would leave the link up and every
      // assertion above would still pass, because an unanswered write resolves
      // unknown on its deadline too.
      await until('the link to go down under the cut',
          () => transitions.contains(LinkState.down),
          budget: recovery);

      // **The plant moved exactly once.** The request arrived whole — only the
      // answer was truncated — so this is 1 rather than 0, and that is the
      // dangerous shape: the caller was told "unknown" about a write that
      // really happened.
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant recorded '
              '${fixture.served.upstreamWriteAttempts(cmd)} attempts for this '
              'command. Zero would mean the request never arrived and this '
              'case is not the row; more than one means something re-sent a '
              'write nobody could confirm');

      // Disarming is what lets the link come back at all, and it is not
      // housekeeping: the cut is **sticky**, so every reconnection would be
      // truncated after its own n bytes — and at this n that is inside the
      // WebSocket handshake response, so no dial would ever complete. Measured:
      // `seam.dials` stays 0 for as long as the lever is armed. Recovery ends
      // by lifting the cut rather than with `killOnce()` because the two modes
      // are mutually exclusive (`fault_proxy.dart:109-116`) and, unlike the
      // blackhole this file's neighbour warns about, the FIN already reached
      // the gateway, so the session is gone and the reconnect is uncontested.
      fixture.proxy.cutMidFrame(null);
      await until('the link back after the cut was lifted',
          () => fixture.client.isReady,
          budget: const Duration(seconds: 15));

      // The recovery asks what became of the command. It never repeats it.
      await until('the writeStatus re-query to be answered about $cmd',
          () => fixture.client.debugWriteStatusAnswers
              .any((result) => result.cmd == cmd),
          budget: recovery);
      final answered = fixture.client.debugWriteStatusAnswers
          .firstWhere((result) => result.cmd == cmd);
      expect(answered, isNot(isA<WriteNotReceived>()),
          reason: 'the gateway answered "never received" about a write it '
              'decoded and forwarded to the plant. That answer sends the '
              'operator back to the button, and the ram moves twice');
      expect(fixture.client.debugWritesSent - sentBefore, 1,
          reason: 'the reconnect re-sent the write. That is the single most '
              'dangerous thing this client could do, and it is why recovery is '
              'a question about the command rather than a repeat of it');
      expect(fixture.served.upstreamWriteAttempts(cmd), 1,
          reason: 'the plant was actuated again by the recovery: '
              '${fixture.served.upstreamWriteAttempts(cmd)} attempts for one '
              'command the operator issued once');
      print('F6: caller verdict $outcome, re-query answered $answered, '
          'plant attempts ${fixture.served.upstreamWriteAttempts(cmd)}');
    },
        skip: Platform.isWindows
            ? 'cutMidFrame cannot target the write answer: the gateway ticks '
                'onto the same line every 100 ms and cannot be slowed past '
                'ServerConfig.maxTick, so on a loaded agent a tick spends the '
                'byte budget and the request never reaches the plant. See the '
                'comment on this case.'
            : null);
  });
}
