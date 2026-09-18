/// The write path: three states, per protocol, with ambiguity resolving to
/// unknown — and the composer's `write`/`writeStatus` on top of it.
///
/// Two subjects in one file because `files_modified` names one test file for
/// both and because they are one subject seen from two ends: the translation
/// decides what a protocol's answer *means*, and the composer is the only
/// place in the package that asks a plant the question.
///
/// The sentence every arm below is defending, from `PROJECT.md` and
/// `write_result.dart:1-8`: **unknown is the safe default and rejected is the
/// claim that needs evidence.** "Rejected" tells an operator it is safe to
/// press the button again; a rejected that was actually applied is a second
/// start command on a machine somebody is standing next to.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
// 08-06 reached this through `src/` and wrote down that "the plan that first
// needs it from outside adds the export line". 08-10 is that plan: the two
// `DeviceClient` adapters name `UpstreamProtocol` and `WriteAnswer` in their
// own public signatures, so leaving the file unexported would make two members
// of an exported class unnameable — and `notWritableReason` is the gateway's
// single spelling of the read-only refusal, which a caller has to be able to
// compare against. The barrel now carries it and the `src/` import is gone.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// A cmd the operator minted. Fixed rather than freshly generated wherever the
/// arm is about translation, so a failure names the same id every time.
const String cmd = '01J0000000000000000000000A';

/// An endpoint string of the shape a real OPC UA failure carries, credentials
/// and all. Every part of it is something that must not reach a panel.
const String credentialledEndpoint =
    'opc.tcp://user:secret@10.104.29.11:4840/relay';

/// A key no keymapping in this file contains, so the router refuses it.
const String unmappedKey = 'ST101.CN99.MOT01.speed';

/// A clock a case can move, so the outcome log's TTL and the evidence rule can
/// be exercised without sleeping for ten minutes.
final class MovableClock {
  MovableClock([DateTime? at]) : _at = at ?? DateTime.now();

  DateTime _at;

  DateTime now() => _at;

  void advance(Duration by) => _at = _at.add(by);

  /// The instant, in the units a ULID is minted in.
  int get ms => _at.millisecondsSinceEpoch;
}

/// One link, one router over it, one composer, wired for the write path.
({LocalStateMan man, FakeUpstreamLink link}) buildWriteFixture({
  bool supportsWrites = true,
  Duration staleAfter = const Duration(seconds: 30),
  Duration writeOutcomeTtl = const Duration(minutes: 10),
  int maxWriteOutcomes = 256,
  DateTime Function()? now,
}) {
  final link = FakeUpstreamLink(
    alias: st101Alias,
    keys: const <String>[st101Key, st201Key],
    supportsWrites: supportsWrites,
  );
  final man = LocalStateMan(
    links: <UpstreamLink>[link],
    router: KeyRouter.overLinks(
      <UpstreamLink>[link],
      mappings: keyMappingsOf(const <String>[st101Key, st201Key],
          alias: st101Alias),
    ),
    staleAfter: staleAfter,
    writeOutcomeTtl: writeOutcomeTtl,
    maxWriteOutcomes: maxWriteOutcomes,
    now: now,
  );
  return (man: man, link: link);
}

/// Waits for [predicate], or fails the case rather than hanging the suite.
Future<void> until(bool Function() predicate,
    {Duration limit = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(limit);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the condition never became true inside $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('OPC UA: a named refusal is rejected, everything else is unknown', () {
    test('GOOD is applied, and the readback is what the operator is shown', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteAcknowledged(readback: 42, at: 1700000000000),
      );
      expect(result, isA<WriteApplied>());
      expect((result as WriteApplied).readback, 42,
          reason: '"applied" means applied AND read back — the UI displays the '
              'readback, never the locally typed value (write_result.dart:117)');
      expect(result.cmd, cmd);
    });

    for (final entry in <int, String>{
      0x801F0000: 'Bad_UserAccessDenied',
      0x803C0000: 'Bad_OutOfRange',
      0x80740000: 'Bad_TypeMismatch',
      0x803B0000: 'Bad_NotWritable',
      0x80340000: 'Bad_NodeIdUnknown',
    }.entries) {
      test('${entry.value} is REJECTED, with the code on the reason', () {
        final result = translateWriteAnswer(
          protocol: UpstreamProtocol.opcUa,
          cmd: cmd,
          answer: WriteStatusAnswer(entry.key),
        );
        expect(result, isA<WriteRejected>(),
            reason: 'the server named a refusal, which is the positive '
                'evidence "rejected" requires. Anything less specific must '
                'stay unknown');
        expect((result as WriteRejected).reason.status, entry.value,
            reason: 'switch on the code, never on the English — the status is '
                'what a later phase maps to an operator-facing sentence');
      });
    }

    test('an unrecognised Bad code is UNKNOWN, not rejected', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        // BadInternalError: a real code, and one that says nothing about
        // whether the node was written before the server gave up.
        answer: const WriteStatusAnswer(0x80020000),
      );
      expect(result, isA<WriteUnknown>(),
          reason: 'a Bad code this gateway does not have a ruling for may be a '
              'service-level failure raised AFTER the node was written. '
              'Calling it rejected invites a second actuation');
    });

    test('a timeout is UNKNOWN — the request may be on the wire', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteDeadlineExpired(),
      );
      expect(result, isA<WriteUnknown>());
      expect((result as WriteUnknown).reason.kind, 'plc_timeout');
    });

    test('a deadline that expired before the link was even reachable is '
        'UNKNOWN too — the gateway cannot tell the two apart', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteDeadlineExpired(requestSent: false),
      );
      expect(result, isA<WriteUnknown>(),
          reason: 'the honest position is that this side does not know which '
              'of the two happened, and a guess in either direction is a '
              'claim it cannot support');
    });

    test('a channel loss (a thrown error) is UNKNOWN', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: WriteThrew(StateError('connection closed mid-write')),
      );
      expect(result, isA<WriteUnknown>());
    });

    test('the string fallback recognises a named code inside the prose', () {
      // 08-01 task 1(d) did not land: `client.dart:485-494` completes the write
      // completer with a formatted String because `isolate.dart` marshals every
      // error across the port as `e.toString()`. This is assumption A3's branch.
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteErrorText('Failed to write value: BadNotWritable'),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Bad_NotWritable',
          reason: 'both spellings appear in the wild (BadNotWritable in the '
              'binding, Bad_NotWritable in the cert overlay) and they are one '
              'code');
    });

    test('an UNPARSED string is UNKNOWN, and the reason says what a wrong '
        '"rejected" costs at a keyboard', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteErrorText('Failed to write value: something new'),
      );
      expect(result, isA<WriteUnknown>(),
          reason: 'THE arm of this file. Rejected means the operator may press '
              'the button again; a rejected that was actually applied is a '
              'second start command on a machine somebody is standing next '
              'to. An unparsed sentence is not evidence of refusal');
      expect((result as WriteUnknown).reason.kind, 'unparsed_upstream_error');
    });

    test('an upstream error string is REDACTED before it becomes a reason', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: const WriteErrorText(
            'write to $credentialledEndpoint failed: BadInternalError'),
      );
      final rendered = result.toJson().toString();
      expect(rendered, isNot(contains('secret')),
          reason: 'T-08-24: a panel with no privileges renders this reason');
      expect(rendered, isNot(contains('user')));
      expect(rendered, isNot(contains('10.104.29.11')),
          reason: 'the endpoint is as much of a disclosure as the password — '
              'it names a machine on the plant network');
      expect(rendered, isNot(contains('4840')));
    });
  });

  group('Modbus: an exception response is the device answering', () {
    test('a function-code echo is applied', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteAcknowledged(readback: true),
      );
      expect(result, isA<WriteApplied>());
    });

    test('an exception response is REJECTED, with its code', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x02),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status,
          'Modbus_IllegalDataAddress');
    });

    test('an exception code outside the table is STILL rejected — unlike OPC '
        'UA, an exception response IS the device refusing', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x7F),
      );
      expect(result, isA<WriteRejected>(),
          reason: 'a Modbus exception PDU is a reply: the slave parsed the '
              'request and declined it. The OPC UA ambiguity does not exist '
              'here, because there is no service layer above the write that '
              'could fail after the register moved');
      expect((result as WriteRejected).reason.status, 'Modbus_Exception_0x7f');
    });

    test('no response inside the deadline is UNKNOWN', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.modbus,
        cmd: cmd,
        answer: const WriteDeadlineExpired(),
      );
      expect(result, isA<WriteUnknown>());
    });
  });

  group('UMAS: a typed exception splits the same way', () {
    test('a typed code is rejected', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.umas,
        cmd: cmd,
        answer: const WriteStatusAnswer(0x0F),
      );
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Umas_0x0f');
    });

    test('an untyped throw is unknown', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.umas,
        cmd: cmd,
        answer: WriteThrew(StateError('socket closed')),
      );
      expect(result, isA<WriteUnknown>(),
          reason: 'the adapter wraps both directions symmetrically '
              '(state_man.dart:2005-2018) and an exception that is not a '
              'typed UMAS refusal is a transport failure, not a refusal');
    });

    test('a timeout is unknown', () {
      expect(
          translateWriteAnswer(
            protocol: UpstreamProtocol.umas,
            cmd: cmd,
            answer: const WriteDeadlineExpired(),
          ),
          isA<WriteUnknown>());
    });
  });

  group('M2400: read-only by protocol answers a refusal, never an exception',
      () {
    test('a write is REJECTED with Bad_NotWritable, in the cert overlay\'s '
        'exact shape', () {
      final result = translateWriteAnswer(
        protocol: UpstreamProtocol.m2400,
        cmd: cmd,
        answer: const WriteDeadlineExpired(),
      );
      expect(result, isA<WriteRejected>(),
          // The citation and the exception name are kept on separate lines on
          // purpose: freeze 5's port sweep reads any four-digit number on a
          // line that also says "port", and `UnsupportedError` contains one.
          // Crude by design (`freeze_test.dart:367-372`), and worth a line
          // break rather than an allow-list entry.
          reason: 'the shipped adapter throws an unsupported-operation error '
              'here (state_man.dart:1266-1268), which reads to a session as '
              '"the write failed for a reason nobody knows". The honest '
              'answer is a refusal, and it is the same refusal '
              'cert_health_state_man.dart:411-424 gives');
      final reason = (result as WriteRejected).reason;
      expect(reason.kind, 'not_writable');
      expect(reason.status, 'Bad_NotWritable',
          reason: 'the contract leg\'s readOnlyKey asserts on the STATUS, not '
              'only on the arm — an operator reading two different refusals '
              'from two layers of one gateway learns nothing from the '
              'difference');
    });

    test('even an acknowledgement is rejected — a read-only device cannot '
        'have applied it', () {
      expect(
          translateWriteAnswer(
            protocol: UpstreamProtocol.m2400,
            cmd: cmd,
            answer: const WriteAcknowledged(readback: 1),
          ),
          isA<WriteRejected>());
    });
  });

  group('the ambiguity rule holds across every protocol', () {
    test('a deadline is unknown for all four, and never rejected', () {
      for (final protocol in UpstreamProtocol.values) {
        final result = translateWriteAnswer(
          protocol: protocol,
          cmd: cmd,
          answer: const WriteDeadlineExpired(),
        );
        if (protocol == UpstreamProtocol.m2400) {
          // The one exception, and it is a rejection for the opposite reason:
          // nothing was ever sent, because the device takes no writes at all.
          expect(result, isA<WriteRejected>());
          continue;
        }
        expect(result, isA<WriteUnknown>(),
            reason: '$protocol turned a lost answer into something other than '
                'unknown');
      }
    });

    test('every translated result carries the operator\'s own cmd', () {
      for (final answer in <WriteAnswer>[
        const WriteAcknowledged(readback: 1),
        const WriteStatusAnswer(0x803B0000),
        const WriteErrorText('nothing recognisable'),
        const WriteDeadlineExpired(),
        WriteThrew(StateError('x')),
      ]) {
        expect(
            translateWriteAnswer(
              protocol: UpstreamProtocol.opcUa,
              cmd: cmd,
              answer: answer,
            ).cmd,
            cmd,
            reason: 'an outcome under a different id is an outcome nothing can '
                'reconcile through writeStatus later');
      }
    });
  });

  group('the array-element ruling: refuse, do not read-modify-write', () {
    test('an array-element write with no expect is REJECTED by name', () {
      final refusal = guardArrayElementWrite(cmd: cmd, hasExpect: false);
      expect(refusal, isA<WriteRejected>(),
          reason: 'state_man.dart:2033-2039 reads the array, replaces one '
              'element and writes it back — not atomic. On a gateway serving '
              'thirty panels a concurrent change between the read and the '
              'write is silently overwritten, which is somebody else\'s '
              'setpoint disappearing');
      expect((refusal! as WriteRejected).reason.kind,
          'array_element_requires_expect',
          reason: 'a named refusal is a page-editor bug report; a silent '
              'overwrite is a plant incident');
    });

    test('with an expect present the write may proceed', () {
      expect(guardArrayElementWrite(cmd: cmd, hasExpect: true), isNull,
          reason: 'the comparison is the guard the read-modify-write needs, '
              'and null here means "no refusal — carry on"');
    });
  });

  group('the composer crosses into the plant exactly once, and never throws',
      () {
    late LocalStateMan man;
    late FakeUpstreamLink link;

    setUp(() async {
      final built = buildWriteFixture();
      man = built.man;
      link = built.link;
      await man.start();
      addTearDown(man.dispose);
    });

    test('an unmapped key is REJECTED with a config reason — never a throw, '
        'and never unknown', () async {
      final before = link.roundTrips;
      final result = await man.write(unmappedKey, 1);

      expect(result, isA<WriteRejected>(),
          reason: 'nothing was sent, so there is nothing to be unsure about. '
              'Unknown here would spend the one distinction the write path '
              'exists to preserve — and it would tell an operator to go and '
              'read back a tag that does not exist');
      expect((result as WriteRejected).reason.kind, 'unroutable_key');
      expect(link.roundTrips, before,
          reason: 'a refusal established before the plant is touched must not '
              'touch the plant');
    });

    test('a PIPE. key is refused — the gateway\'s own namespace is not a place '
        'a client writes', () async {
      final result = await man.write('PIPE.upstream.st101.state', 'connected');
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.kind, 'unroutable_key');
    });

    test('a mapped key calls the link EXACTLY once and returns its outcome',
        () async {
      final before = link.roundTrips;
      final result = await man.write(st101Key, 41);

      expect(result, isA<WriteApplied>());
      expect((result as WriteApplied).readback, 41);
      expect(link.roundTrips - before, 1,
          reason: 'one operator action is one crossing into the plant. The '
              'static pin in freeze_test counts call SITES; this counts '
              'attempts, which is the property the site count is a proxy for');
    });

    test('a lost answer comes back UNKNOWN, and does not throw through the '
        'session', () async {
      link.setNextWriteOutcome(
          WriteUnknown(cmd, const WriteReason('plc_timeout')));
      final result = await man.write(st101Key, 1);
      expect(result, isA<WriteUnknown>());
    });

    test('a read-only link answers WriteRejected with Bad_NotWritable, not an '
        'UnsupportedError', () async {
      final readOnly = buildWriteFixture(supportsWrites: false);
      await readOnly.man.start();
      addTearDown(readOnly.man.dispose);

      final result = await readOnly.man.write(st101Key, 1);
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.status, 'Bad_NotWritable',
          reason: 'M2400DeviceClientAdapter.write throws UnsupportedError '
              '(state_man.dart:1266-1268). A read-only device has an answer '
              'and it is a refusal');
    });

    test('BEHAVIORAL no-retry: a write during a link-down window is attempted '
        'ONCE, and nothing re-issues it when the link comes back', () async {
      link.disconnectUpstream();
      final before = link.roundTrips;

      final result = await man.write(st101Key, 1);
      expect(result, isA<WriteUnknown>(),
          reason: 'the link was down, so this side cannot say the PLC did not '
              'take it');
      expect(link.roundTrips - before, 1);

      link.reconnectUpstream();
      // Several turns of the event loop, which is all a reconnect-driven
      // re-issue would need.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(link.roundTrips - before, 1,
          reason: 'T-08-22. A reconnect may re-subscribe — that is resync and '
              'the design endorses it — but it must never re-issue a write. '
              'A repeated unknown write is one actuation the operator did not '
              'ask for, and on a hold engage it is a jog nobody is holding. '
              '08-07 runs this same arm against a real in-process server');
    });

    test('the cmd the operator minted is the cmd the outcome carries', () async {
      final result = await man.write(st101Key, 1, cmd: cmd);
      expect(result.cmd, cmd,
          reason: 'behind a gateway, a plant that minted its own id would make '
              '"how many times did this operator action reach the device" a '
              'question nothing on either side could answer');
    });

    test('a cmd nobody supplied is minted here, and it is a datable ULID',
        () async {
      final result = await man.write(st101Key, 1);
      expect(result.cmd, hasLength(26));
      expect(await man.writeStatus(<String>[result.cmd]),
          <Matcher>[isA<WriteApplied>()],
          reason: 'a minted id that writeStatus cannot answer for is an id '
              'nothing can reconcile after a reconnect');
    });

    test('a re-used cmd is an ArgumentError — the reference implementation\'s '
        'strictness, matched', () async {
      await man.write(st101Key, 1, cmd: cmd);
      expect(() => man.write(st101Key, 2, cmd: cmd), throwsArgumentError,
          reason: 'fake_state_man.dart:660-670. One id is one operator '
              'action: a second write under it would be a second actuation '
              'reported under the first one\'s outcome. The idempotency '
              'WINDOW (same cmd + same key/value answered from the log) lives '
              'at value_handlers.write, one layer up — the source stays '
              'strict, and the gateway maps this throw to '
              'WriteUnknown(gateway_lost_track)');
    });

    test('a write on a disposed source is a StateError, not an outcome',
        () async {
      final disposable = buildWriteFixture();
      await disposable.man.start();
      await disposable.man.dispose();
      expect(() => disposable.man.write(st101Key, 1), throwsStateError,
          reason: 'no outcome reported here could be true — the store and the '
              'link are both gone. This is a lifecycle bug in the caller and '
              'not a write outcome');
    });

    test('an expect that does not match the last known value is REJECTED, and '
        'nothing is sent', () async {
      man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 5),
      });
      final before = link.roundTrips;

      final result = await man.write(st101Key, 9, expect: 4);
      expect(result, isA<WriteRejected>());
      expect((result as WriteRejected).reason.kind, 'expect_mismatch',
          reason: 'a compare-and-set that was silently ignored would be worse '
              'than one that is refused: the caller believes it is guarded');
      expect(link.roundTrips, before);
    });

    test('an expect that matches proceeds', () async {
      man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 5),
      });
      expect(await man.write(st101Key, 9, expect: 5), isA<WriteApplied>());
    });

    test('a value the wire cannot represent is REJECTED before the plant is '
        'touched', () async {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      final before = link.roundTrips;

      final result = await man.write(st101Key, cyclic);
      expect(result, isA<WriteRejected>(),
          reason: 'sanitize throws ArgumentError on a cycle or a depth past '
              '64. A throw here would read to the operator as "the write '
              'failed for an unknown reason"; the honest answer is a refusal, '
              'and it is definitively no effect');
      expect((result as WriteRejected).reason.kind, 'unrepresentable_value');
      expect(link.roundTrips, before);
    });
  });

  group('a write is visibly unconfirmed WHILE IN FLIGHT, and confirmed by its '
      'readback', () {
    // **Rewritten by 08-11, and the contract suite is why.** 08-06 badged the
    // value AFTER the outcome and left the badge on until some later upstream
    // sample. Two of the fifty checks say that is wrong in both halves:
    //
    //  * `checkWritePendingIsVisibleWhileInFlight` holds a write open and
    //    requires the badge to be visible THEN — "over a slow link it is the
    //    only thing telling an operator their press was registered, and an
    //    operator who sees nothing presses again". A badge staged after the
    //    outcome is never visible during the one window it exists for.
    //  * The same check then requires the value to read `good` once the write
    //    resolves: "a pending badge that never clears is a permanent amber box
    //    the operator learns to ignore".
    //
    // And the badge coming off on `WriteApplied` is not a weakening of
    // "readback is the only confirmation" — it is that rule applied, because
    // `upstream_link.dart` defines applied as "applied *and read back*". The
    // confirmation is the outcome, and it carries the number the device holds.
    test('the badge is ON while the write is out and OFF once it lands, and '
        'the number that lands is the READBACK', () async {
      final built = buildWriteFixture();
      await built.man.start();
      addTearDown(built.man.dispose);
      built.man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 1),
      });

      // Held open at the link, which is where a slow PLC holds one.
      built.link.writeLatency = const Duration(milliseconds: 80);
      final pending = built.man.write(st101Key, 7);

      expect(built.man.read(st101Key)!.quality, Quality.goodWritePending,
          reason: 'the in-flight window is a property of the value, not of a '
              'handle object somebody has to remember to hold');
      expect(built.man.read(st101Key)!.value, 1,
          reason: 'the value showed the number that was TYPED while the write '
              'was still out; that is a confirmation nothing upstream has '
              'given');
      expect(built.man.writePendingKeys, contains(st101Key));

      final result = await pending;
      expect(result, isA<WriteApplied>());
      expect(built.man.read(st101Key)!.quality, Quality.good,
          reason: 'the write landed and its readback IS the confirmation');
      expect(built.man.read(st101Key)!.value, 7);
      expect(built.man.writePendingKeys, isEmpty);
    });

    test('a CLAMPED readback is what the store shows — never the number that '
        'was typed', () async {
      final built = buildWriteFixture();
      await built.man.start();
      addTearDown(built.man.dispose);
      built.man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 1200),
      });
      // A PLC clamping a setpoint to its configured maximum is ordinary, and
      // it is the case that separates a source which reads back from one which
      // merely remembers: if the mimic shows 5000 while the machine runs at
      // 1500, the operator has been told the plant is doing something it is
      // not — and told it BY THE CONFIRMATION.
      built.link.setNextWriteOutcome(
          WriteApplied(cmd, readback: 1500, at: 1700000000000));

      final result = await built.man.write(st101Key, 5000);

      expect((result as WriteApplied).readback, 1500);
      expect(built.man.read(st101Key)!.value, 1500,
          reason: 'the cache must hold what the device holds');
      expect(built.man.listen(st101Key).value.value, 1500,
          reason: 'listen() and the device must not disagree — the widget '
              'bound to this key would draw a number nobody upstream agreed '
              'to');
      expect(built.man.writePendingKeys, isEmpty);
    });

    test('a sample that never comes leaves the badge until STALENESS overtakes '
        'it — the operator sees "sent", then "do not trust this"', () async {
      final built = buildWriteFixture(staleAfter: const Duration(milliseconds: 60));
      final man = built.man;
      await man.start();
      addTearDown(man.dispose);
      man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 1),
      });

      // An outcome NOBODY KNOWS is the arm this is really about since 08-11:
      // an applied write now carries its own confirmation, so the badge that
      // can outlive its own meaning is the one left by a write whose answer
      // never came. The badge comes off — nothing was confirmed and nothing
      // was refused — and the last confirmed reading is left to go stale on
      // its own clock, which is the operator seeing "sent", then "do not
      // trust this".
      built.link.setNextWriteOutcome(WriteUnknown(
          cmd, const WriteReason('plc_timeout', message: 'no answer came')));
      await man.write(st101Key, 7);
      expect(man.read(st101Key)!.value, 1,
          reason: 'an unknown outcome must not leave the typed number on the '
              'screen: nothing upstream agreed to it');
      expect(man.writePendingKeys, isEmpty,
          reason: 'the badge means SENT AND WAITING; a write nobody has an '
              'answer for is not waiting on anything this source will hear');

      // A watcher, because the sweep's clock is listener-gated.
      final handle = man.listen(st101Key);
      void noop() {}
      handle.addListener(noop);
      addTearDown(() => handle.removeListener(noop));

      await until(() => handle.value.quality == Quality.badStale);
      expect(man.writePendingKeys, isEmpty,
          reason: 'a pending badge that outlived the freshness deadline would '
              'read as "sent a moment ago" on a value nobody has heard about '
              'for a minute');
    });

    test('a write does NOT badge a value that is already worse than good — a '
        'write must not make a dead tag look alive', () async {
      final built = buildWriteFixture();
      await built.man.start();
      addTearDown(built.man.dispose);
      built.man.applyUpstreamBatch(<String, DynamicValue>{
        st101Key: DynamicValue(value: 1, quality: Quality.badCommFault),
      });

      built.link.setNextWriteOutcome(
          WriteApplied(cmd, readback: 7, at: 1700000000000));
      await built.man.write(st101Key, 7);

      expect(built.man.read(st101Key)!.quality, Quality.badCommFault,
          reason: 'fake_state_man.dart:936-938\'s band guard. '
              'goodWritePending is a GOOD-band code, so stamping it over a '
              'comm fault would make a write a way of making a dead tag look '
              'healthy');
    });
  });

  group('writeStatus answers positionally, from a bounded plant-side log', () {
    test('a recorded outcome is the answer, at its own position', () async {
      final built = buildWriteFixture();
      await built.man.start();
      addTearDown(built.man.dispose);

      final applied = await built.man.write(st101Key, 1);
      final refused = await built.man.write(unmappedKey, 1);

      final answers = await built.man
          .writeStatus(<String>[refused.cmd, 'not-a-ulid', applied.cmd]);

      expect(answers, hasLength(3));
      expect(answers[0], isA<WriteRejected>());
      expect(answers[1], isA<WriteUnknown>());
      expect(answers[2], isA<WriteApplied>());
      expect(answers[2].cmd, applied.cmd,
          reason: 'element i answers cmds[i]. A caller reconciling a reconnect '
              'must not have to trust a map key round trip to know which '
              'command it is being told about');
    });

    test('an id that is not a datable ULID is unknown — nothing about it can '
        'be ruled out', () async {
      final built = buildWriteFixture();
      addTearDown(built.man.dispose);
      final answers = await built.man.writeStatus(<String>['banana']);
      expect(answers.single, isA<WriteUnknown>());
      expect((answers.single as WriteUnknown).reason.kind, 'unrecognized_cmd');
    });

    test('an id minted before this source started, or ahead of its clock, is '
        'unwitnessed — forgetting is not evidence of never happening',
        () async {
      final clock = MovableClock();
      final built = buildWriteFixture(now: clock.now);
      addTearDown(built.man.dispose);

      final old = newUlid(nowMs: clock.ms - const Duration(hours: 1).inMilliseconds);
      final future =
          newUlid(nowMs: clock.ms + const Duration(hours: 1).inMilliseconds);

      final answers = await built.man.writeStatus(<String>[old, future]);
      for (final answer in answers) {
        expect(answer, isA<WriteUnknown>());
        expect((answer as WriteUnknown).reason.kind, 'outcome_unwitnessed',
            reason: 'a panel whose clock runs fast must not buy itself a '
                're-send window');
      }
    });

    test('an id minted inside the window and never seen is the ONE re-send-safe '
        'answer', () async {
      final clock = MovableClock();
      final built = buildWriteFixture(now: clock.now);
      addTearDown(built.man.dispose);

      clock.advance(const Duration(seconds: 1));
      final never = newUlid(nowMs: clock.ms);

      final answer = (await built.man.writeStatus(<String>[never])).single;
      expect(answer, isA<WriteNotReceived>());
      expect(answer.isSafeToResend, isTrue,
          reason: 'all four pieces of positive evidence hold: datable, minted '
              'after this source started recording, not in the future, and '
              'inside the TTL');
    });

    test('a cmd past the TTL answers unknown rather than growing the map '
        'forever', () async {
      final clock = MovableClock();
      final built = buildWriteFixture(
          now: clock.now, writeOutcomeTtl: const Duration(minutes: 10));
      await built.man.start();
      addTearDown(built.man.dispose);

      final applied = await built.man.write(st101Key, 1, cmd: newUlid(nowMs: clock.ms));
      expect((await built.man.writeStatus(<String>[applied.cmd])).single,
          isA<WriteApplied>());

      clock.advance(const Duration(minutes: 11));
      final answer = (await built.man.writeStatus(<String>[applied.cmd])).single;

      expect(answer, isA<WriteUnknown>());
      expect((answer as WriteUnknown).reason.kind, 'outcome_expired');
      expect(built.man.writeOutcomeCount, 0,
          reason: 'a gateway serving a plant for months cannot keep every '
              'outcome it has ever settled');
    });

    test('the log is capped, the OLDEST goes first, and an evicted cmd answers '
        'unknown — never not_received', () async {
      final built = buildWriteFixture(maxWriteOutcomes: 4);
      await built.man.start();
      addTearDown(built.man.dispose);

      final first = await built.man.write(st101Key, 0);
      for (var i = 1; i <= 5; i++) {
        await built.man.write(st101Key, i);
      }

      expect(built.man.writeOutcomeCount, 4);
      final answer = (await built.man.writeStatus(<String>[first.cmd])).single;
      expect(answer, isA<WriteUnknown>(),
          reason: 'this write WAS received and may well have moved the '
              'machine. An eviction that let the evidence rule answer '
              'not_received would hand the operator a re-send window for a '
              'command the plant already took — the log has to remember that '
              'it forgot');
      expect((answer as WriteUnknown).reason.kind, 'outcome_forgotten');
      expect(answer.isSafeToResend, isFalse);
    });

    test('a mismatched entry is substituted IN PLACE, never shifted', () {
      final answers = alignWriteStatusAnswers(
        <String>['a', 'b', 'c'],
        <WriteResult>[
          const WriteNotReceived('a'),
          // The wrong cmd at position 1, which is what a shifted list looks
          // like from the outside.
          const WriteNotReceived('c'),
          const WriteNotReceived('c'),
        ],
      );

      expect(answers.map((answer) => answer.cmd), <String>['a', 'b', 'c'],
          reason: 'the positional promise is the whole point: an answer '
              'shifted by one tells an operator about a different machine');
      expect(answers[1], isA<WriteUnknown>());
      expect((answers[1] as WriteUnknown).reason.kind, 'misaligned_result');
      expect(answers[2], isA<WriteNotReceived>(),
          reason: 'the entries AFTER a mismatch keep their own answers — '
              'substitution in place, not a shift');
    });

    test('a short answer list is padded in place rather than truncating the '
        'question', () {
      final answers = alignWriteStatusAnswers(
        <String>['a', 'b'],
        <WriteResult>[const WriteNotReceived('a')],
      );
      expect(answers, hasLength(2));
      expect(answers[1], isA<WriteUnknown>());
    });
  });

  // ------------------------------------------------------------ 08-REVIEW
  group('CR-03: the TTL path forgets out loud, exactly as the cap path does',
      () {
    test('a cmd minted on a panel whose clock runs AHEAD is unknown after the '
        'TTL, never not_received', () async {
      final clock = MovableClock();
      final built = buildWriteFixture(
          now: clock.now, writeOutcomeTtl: const Duration(minutes: 10));
      await built.man.start();
      addTearDown(built.man.dispose);

      // The panel's clock is thirty seconds ahead of the gateway's, which is
      // an ordinary amount of skew on a plant where not everything runs NTP.
      // The cmd is minted THERE (`value_handlers.dart:677` passes request.cmd
      // straight through), and the outcome is settled HERE.
      const skew = Duration(seconds: 30);
      final cmd = newUlid(nowMs: clock.ms + skew.inMilliseconds);
      final applied = await built.man.write(st101Key, 1, cmd: cmd);
      expect(applied, isA<WriteApplied>());

      // Far enough that the entry ages out on the GATEWAY's clock, and not so
      // far that the cmd's own ULID looks old: this is the whole window.
      clock.advance(const Duration(minutes: 10, milliseconds: 1));
      final answer = (await built.man.writeStatus(<String>[cmd])).single;

      expect(built.man.writeOutcomeCount, 0,
          reason: 'anti-vacuity: the entry must actually have been pruned, or '
              'this case is reading a held outcome');
      expect(answer, isA<WriteUnknown>(),
          reason: 'the gateway performed this write. not_received is '
              'documented as the one answer that tells an operator a re-send '
              'is safe, and a re-send here is a second unrequested actuation');
      expect(answer.isSafeToResend, isFalse);
      expect((answer as WriteUnknown).reason.kind, 'outcome_forgotten',
          reason: 'the TTL path has to move the same watermark the cap path '
              'moves — "the log has to remember that it forgot" holds for '
              'both ways of forgetting, not just the tidy one');
    });

    test('and a cmd the gateway genuinely never saw is STILL not_received',
        () async {
      final clock = MovableClock();
      final built = buildWriteFixture(
          now: clock.now, writeOutcomeTtl: const Duration(minutes: 10));
      await built.man.start();
      addTearDown(built.man.dispose);

      // One settled write ages out and moves the watermark to its own mint
      // time...
      final old = newUlid(nowMs: clock.ms);
      await built.man.write(st101Key, 1, cmd: old);
      clock.advance(const Duration(minutes: 10, milliseconds: 1));
      await built.man.writeStatus(<String>[old]);

      // ...and a cmd minted AFTER that watermark, which this gateway has never
      // heard of, keeps the positive-evidence answer. Widening the watermark
      // into a blanket "everything is unknown" would cost the operator the one
      // answer that makes a re-send safe, which is the Phase 4 rule.
      final fresh = newUlid(nowMs: clock.ms);
      final answer = (await built.man.writeStatus(<String>[fresh])).single;

      expect(answer, isA<WriteNotReceived>(),
          reason: 'not_received still requires positive evidence and still '
              'gets it: datable, minted after this source started recording, '
              'not in the future, inside the TTL, and after everything the '
              'log admits to having forgotten');
      expect(answer.isSafeToResend, isTrue);
    });
  });

  group('WR-08: the minted-id set is bounded like the log it guards', () {
    test('ids age out with the outcomes they belong to', () async {
      final clock = MovableClock();
      final built = buildWriteFixture(
          now: clock.now, writeOutcomeTtl: const Duration(minutes: 10));
      await built.man.start();
      addTearDown(built.man.dispose);

      for (var i = 0; i < 20; i++) {
        await built.man.write(st101Key, i, cmd: newUlid(nowMs: clock.ms));
        clock.advance(const Duration(seconds: 1));
      }
      expect(built.man.mintedCmdCount, 20,
          reason: 'anti-vacuity: they are all inside the window so far');

      clock.advance(const Duration(minutes: 11));
      await built.man.writeStatus(const <String>[]);

      expect(built.man.mintedCmdCount, 0,
          reason: 'a gateway runs for months. An unbounded set of every '
              '26-character id it has ever seen is the same leak _outcomes is '
              'capped to avoid, without even an audit trail to show for it');
      expect(built.man.writeOutcomeCount, 0);
    });

    test('and it is capped by count too, for an id no ULID time can be read '
        'out of', () async {
      final built = buildWriteFixture(maxWriteOutcomes: 4);
      await built.man.start();
      addTearDown(built.man.dispose);

      for (var i = 0; i < 12; i++) {
        await built.man.write(st101Key, i);
      }

      expect(built.man.mintedCmdCount, lessThanOrEqualTo(4),
          reason: 'the TTL drop cannot see an id that is not a datable ULID, '
              'so the cap is what makes the bound unconditional');
      expect(built.man.writeOutcomeCount, 4);
    });
  });
}
