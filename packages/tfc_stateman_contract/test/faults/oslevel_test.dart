/// The half of the fault kit a userspace proxy structurally cannot do.
///
/// `FaultProxy` sees a byte stream. The kernel sees packets. Everything the
/// proxy can express — cut the connection, withhold a direction, delay the
/// bytes — is a *stream* fault, and no arrangement of `Socket.add` calls can
/// drop one packet, deliver two copies of it, or hand the peer packet 7 before
/// packet 6. TCP reassembles in order by definition, so a stream-level harness
/// cannot even *observe* reordering. That is why this file exists and why its
/// reorder and duplicate arms speak UDP: they are asserting on the packet
/// layer, which is the only layer where those faults are visible at all.
///
/// Everything here is measured against `tc netem` on Linux
/// (RESEARCH Finding 12, whose command matrix was executed in `ubuntu:24.04`
/// with `--cap-add=NET_ADMIN`). Three of that finding's results shape this file
/// directly:
///
/// - **`delay` is per-traversal, not per-round-trip.** netem shapes egress, and
///   a loopback round trip crosses `lo`'s egress twice, so `delay 50ms`
///   measured a **108 ms** RTT. The delay arm asserts against
///   [loopbackRoundTripFor], which is the one place that factor of two lives.
/// - **`change` and `replace` merge rather than replace.** A previous arm's
///   parameter survives into the next one and surfaces as a failure somewhere
///   unrelated. Setup is `del`-then-`add`, always, and
///   ["a fresh install inherits nothing"] asserts it at runtime rather than
///   trusting a grep.
/// - **`del` with nothing installed exits 2.** Teardown tolerates it, which is
///   what lets teardown be unconditional.
///
/// The teardown-integrity group is the one that earns its keep on a bad day: a
/// 100 %-loss qdisc left on `lo` degrades every connection on the machine until
/// someone reboots or thinks to look, so [installNetem] registers its own
/// removal the moment the `add` succeeds and a test whose body throws still
/// cleans up (threat T-02-15).
///
/// Where the machine cannot do this — no `tc`, or `tc` without root — every
/// group skips **by name**, carrying the probe's reason. `if (!hasRoot) return;`
/// reports as a pass, which would make a leg that runs nowhere look exactly
/// like a leg that runs everywhere.
@Tags(['oslevel'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The delay each arm installs, per traversal of the interface.
///
/// 50 ms is large enough that no scheduler hiccup on a loaded CI runner can
/// counterfeit it, and small enough that the arm costs under a second.
const _delay = Duration(milliseconds: 50);

/// How many datagrams the packet-layer arms send.
///
/// One byte carries the sequence number, so this must stay under 256. At 100
/// packets a 50 % reorder rate that produced no inversion at all would be a
/// 1-in-2^99 event — the arm fails when netem is not working, not when the
/// dice are unkind.
const _datagrams = 100;

/// Round-trips one byte through a loopback echo server and times it.
///
/// Nagle is off on both ends deliberately: with it on, the kernel may sit on a
/// single-byte write waiting for more, and the arm would be timing TCP's
/// coalescing heuristics rather than the qdisc.
Future<Duration> _roundTrip(Socket client, Stream<Uint8List> echoes) async {
  final stopwatch = Stopwatch()..start();
  client.add(const [0x2a]);
  await within(
    echoes.first,
    'the echo of one byte came back through the loopback connection',
    budget: const Duration(seconds: 10),
  );
  return stopwatch.elapsed;
}

/// A loopback TCP connection whose server end echoes everything back.
///
/// Returned as a record because both ends matter to the caller: the client to
/// write on, and the broadcast echo stream to await. The listener and both
/// socket ends are closed through [addTearDown] here, so no arm has to
/// remember them.
Future<({Socket client, Stream<Uint8List> echoes})> _echoConnection() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final serverSide = <Socket>[];
  addTearDown(() {
    for (final socket in serverSide) {
      socket.destroy();
    }
  });
  server.listen((socket) {
    serverSide.add(socket);
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.listen(socket.add, onError: (Object _) {});
  });

  final client = await within(
    Socket.connect(InternetAddress.loopbackIPv4, server.port),
    'the loopback echo connection was established',
    budget: const Duration(seconds: 5),
  );
  client.setOption(SocketOption.tcpNoDelay, true);
  addTearDown(client.destroy);
  return (client: client, echoes: client.asBroadcastStream());
}

/// Sends [_datagrams] sequenced UDP packets over loopback and reports what
/// arrived, in arrival order.
///
/// The sequence byte is the payload, so the returned list *is* the observed
/// ordering — an inversion in it is a reordered packet and a repeat in it is a
/// duplicated one. Returns the number actually handed to the kernel alongside,
/// because a `send` that returned 0 would otherwise look like a dropped packet.
Future<({List<int> received, int sent})> _sendDatagrams({
  required Duration settle,
}) async {
  final receiver =
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(receiver.close);
  addTearDown(sender.close);

  final received = <int>[];
  final subscription = receiver.listen((event) {
    if (event != RawSocketEvent.read) return;
    for (var datagram = receiver.receive();
        datagram != null;
        datagram = receiver.receive()) {
      received.add(datagram.data.first);
    }
  });
  addTearDown(subscription.cancel);

  var sent = 0;
  for (var i = 0; i < _datagrams; i++) {
    if (sender.send([i], receiver.address, receiver.port) > 0) sent++;
  }

  // A measurement wait, not synchronisation: the delayed half of a reordered
  // stream has no completion event to await, and counting before it lands
  // would read netem's delay as packet loss.
  await Future<void>.delayed(settle);
  return (received: received, sent: sent);
}

/// The stock `/etc/pf.conf`, as read from macOS 15.1.1 while writing this.
///
/// A fixture rather than a read of the live file: the assertion is that the
/// splice preserves *these* anchors, which is only a meaningful claim if the
/// input cannot quietly change underneath it. Note what is absent — the
/// `set skip on lo0` line usually blamed for pf ignoring loopback is not
/// there, and `dummynet-anchor` is.
const _stockPfConf = '''
#
# Default PF configuration file.
#
# Care must be taken to ensure that the main ruleset does not get flushed,
# as the nested anchors rely on the anchor point defined here.
#
# See pf.conf(5) for syntax.
#

#
# com.apple anchor point
#
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
''';

Future<void> main() async {
  // ---------------------------------------------------------------------
  // Command construction. No privileges, no kernel — these run everywhere
  // the tag is selected, and they are what stops a hostile interface name or
  // a resurrected `tc qdisc change` from reaching a root shell.
  // ---------------------------------------------------------------------
  group('netem command construction', () {
    test('installs with del-then-add, never change or replace', () {
      final add = netemAddArgv('lo', const NetemSpec(delay: _delay));

      expect(add, ['sudo', '-n', 'tc', 'qdisc', 'add', 'dev', 'lo', 'root',
        'netem', 'delay', '50ms']);
      expect(netemDeleteArgv('lo'),
          ['sudo', '-n', 'tc', 'qdisc', 'del', 'dev', 'lo', 'root']);
      expect([...add, ...netemDeleteArgv('lo'), ...netemShowArgv('lo')],
          isNot(anyElement(anyOf('change', 'replace'))),
          reason: 'RESEARCH Finding 12 measured both keywords preserving '
              'unspecified parameters, so an arm that sets only delay would '
              'silently run under a previous arm rate limit and fail '
              'somewhere else entirely');
    });

    test('every command is an argument vector, not a sentence', () {
      final everything = [
        ...netemAddArgv(
            'lo',
            const NetemSpec(
              delay: _delay,
              jitter: Duration(milliseconds: 10),
              lossPercent: 100,
              reorderPercent: 25,
              reorderCorrelationPercent: 50,
              duplicatePercent: 1,
              corruptPercent: 0.1,
            )),
        ...netemDeleteArgv('lo'),
        ...netemShowArgv('lo'),
        ...dnctlPipeConfigArgv(
            pipe: 1, delay: _delay, bandwidth: '1Mbit/s'),
        ...dnctlFlushArgv(),
        ...pfctlLoadArgv('/tmp/rules.conf'),
        ...pfctlEnableArgv(),
        ...pfctlDisableArgv(),
      ];

      expect(everything, everyElement(isNot(contains(' '))),
          reason: 'an argument containing a space is the fingerprint of a '
              'command assembled as a string; these all go to Process.run as '
              'a List<String> so that an interface name can never become a '
              'command (threat T-02-14)');
      expect(everything, everyElement(isNot(anyOf(contains(';'),
          contains('|'), contains('&'), contains(r'$'), contains('`')))));
    });

    test('renders a full spec in the order Finding 12 executed', () {
      expect(
        const NetemSpec(
          delay: Duration(milliseconds: 20),
          jitter: Duration(milliseconds: 10),
          reorderPercent: 25,
          reorderCorrelationPercent: 50,
          duplicatePercent: 1,
          corruptPercent: 0.1,
        ).toArgs(),
        ['delay', '20ms', '10ms', 'reorder', '25%', '50%', 'duplicate', '1%',
          'corrupt', '0.1%'],
      );
      expect(const NetemSpec(lossPercent: 100).toArgs(), ['loss', '100%']);
    });

    test('refuses an interface that is not on the allow-list', () {
      for (final hostile in [
        'lo; rm -rf /',
        r'$(whoami)',
        'lo root netem loss 100%',
        '../../etc/passwd',
        '',
        'eth0',
      ]) {
        expect(() => netemAddArgv(hostile, const NetemSpec(delay: _delay)),
            throwsArgumentError,
            reason: 'a device name reaches a root shell, so the gate is an '
                'allow-list of the interfaces this harness shapes '
                '($netemShapeableDevices) rather than a blocklist of the '
                'metacharacters someone thought of');
      }
      for (final allowed in netemShapeableDevices) {
        expect(netemAddArgv(allowed, const NetemSpec(delay: _delay)),
            contains(allowed));
      }
    });

    test('refuses a spec the kernel would accept and quietly ignore', () {
      expect(() => const NetemSpec().toArgs(), throwsArgumentError,
          reason: 'an empty netem installs a qdisc that shapes nothing, and '
              'an arm running under it passes while injecting no fault at all');
      expect(() => const NetemSpec(reorderPercent: 25).toArgs(),
          throwsArgumentError,
          reason: 'tc rejects reorder without delay, and a helper that only '
              'finds out at the root shell reports it as a privilege problem');
    });

    test('states the loopback round trip is two traversals', () {
      expect(loopbackRoundTripFor(_delay), _delay * 2,
          reason: 'RESEARCH measured delay 50ms as a 108 ms RTT; an assertion '
              'written against the other convention is off by exactly 2x, and '
              'that factor lives here rather than in each arm');
    });

    test('builds the pf rules that classify loopback into a pipe', () {
      final rules = dummynetLoopbackRules(pipe: 1);
      expect(rules, contains('dummynet in'));
      expect(rules, contains('dummynet out'));
      expect(rules, contains(dummynetLoopbackInterface));
      expect(rules, contains('pipe 1'));
      expect(() => dummynetLoopbackRules(pipe: 0), throwsArgumentError);
      expect(() => dnctlPipeConfigArgv(pipe: -1, delay: _delay),
          throwsArgumentError);
      expect(() => dnctlPipeConfigArgv(pipe: 1), throwsArgumentError,
          reason: 'a pipe configured with neither delay nor bandwidth shapes '
              'nothing, which is the spike failing silently');
    });

    test('adds the dummynet rules to the system ruleset without flushing it',
        () {
      final spliced =
          pfRulesetWithDummynet(baseRuleset: _stockPfConf, pipe: 1);

      for (final anchor in [
        'scrub-anchor "com.apple/*"',
        'nat-anchor "com.apple/*"',
        'rdr-anchor "com.apple/*"',
        'dummynet-anchor "com.apple/*"',
        'anchor "com.apple/*"',
        'load anchor "com.apple" from "/etc/pf.anchors/com.apple"',
      ]) {
        expect(spliced, contains(anchor),
            reason: 'pfctl -f replaces the active ruleset, and /etc/pf.conf '
                'opens by warning that its nested anchors rely on staying '
                'loaded. Dropping $anchor for the duration of a spike is a '
                'firewall change on a developer machine (threat T-02-17)');
      }

      final lines = spliced.split('\n');
      expect(lines.indexWhere((l) => l.startsWith('dummynet in')),
          greaterThan(lines.indexWhere((l) => l.startsWith('dummynet-anchor'))),
          reason: 'pf orders rule types strictly — normalisation, '
              'translation, then filtering — so the position is load-bearing '
              'and a wrong one is a parse error');
      expect(lines.indexWhere((l) => l.startsWith('dummynet out')),
          lessThan(lines.indexWhere((l) => l.startsWith('anchor "com.apple'))));

      expect(() => pfRulesetWithDummynet(baseRuleset: '', pipe: 1),
          throwsArgumentError,
          reason: 'a ruleset with no anchor to place these against is one '
              'this helper must refuse rather than guess at, because the '
              'guess would be a position in somebody firewall configuration');
    });
  });

  // ---------------------------------------------------------------------
  // What the teardown does on a bad day. Every step needs root, so the
  // runner is substituted: the property under test is the *ordering and
  // independence* of the steps, which is a property of this function and not
  // of pf, and a test that could only run with sudo would be exercising the
  // happy path on the one machine where the residue does not matter.
  // ---------------------------------------------------------------------
  group('dummynet teardown', () {
    test('restores the ruleset first, and attempts every step even after one '
        'fails', () async {
      final attempted = <List<String>>[];
      final directory =
          await Directory.systemTemp.createTemp('dummynet_teardown_test');

      Future<void> failEverything(List<String> argv, String what) async {
        attempted.add(argv);
        throw StateError('could not $what (exit 1): deliberate');
      }

      final failure = await restoreFromDummynet(
        wasEnabled: false,
        directory: directory,
        run: failEverything,
      ).then<Object?>((_) => null, onError: (Object error) => error);

      expect(attempted.first, pfctlLoadArgv('/etc/pf.conf'),
          reason: 'the pf.conf reload is the step whose omission leaves a '
              'developer Mac running the spike ruleset with pf enabled '
              '(threat T-02-17), so it cannot be gated on the flush '
              'succeeding — it goes first, and every other step goes after it '
              'whatever it did');
      expect(attempted, [
        pfctlLoadArgv('/etc/pf.conf'),
        dnctlFlushArgv(),
        pfctlDisableArgv(),
      ],
          reason: 'a teardown of sequential throwing calls stops at the first '
              'failure and leaves the machine shaped in exactly the way this '
              'function documents it will not. Each step has to be attempted '
              'on its own');
      expect(directory.existsSync(), isFalse,
          reason: 'the temp ruleset outlived a failing teardown, so a run '
              'that fails leaves a directory of pf rules behind every time');

      expect(failure, isA<StateError>(),
          reason: 'a teardown that swallowed three root-level failures would '
              'report a restored machine that is still shaped, which is worse '
              'than the failure it hid');
      final report = failure.toString();
      expect(report, contains('MAY STILL BE SHAPED'));
      expect(report, contains(pfctlLoadArgv('/etc/pf.conf').join(' ')),
          reason: 'the person reading this is the one who has to finish the '
              'restoration by hand, so the message carries the commands');
      expect(report, contains(dnctlFlushArgv().join(' ')));
      expect('MAY STILL BE SHAPED'.allMatches(report).length, 1,
          reason: 'the three failures are collected into one report rather '
              'than one exception each: a teardown throwing from inside a '
              'teardown loses the ones that came after it');
    });

    test('leaves pf enabled when it was found enabled, and says nothing when '
        'every step worked', () async {
      final attempted = <List<String>>[];
      final directory =
          await Directory.systemTemp.createTemp('dummynet_teardown_test');

      await restoreFromDummynet(
        wasEnabled: true,
        directory: directory,
        run: (argv, what) async => attempted.add(argv),
      );

      expect(attempted, [pfctlLoadArgv('/etc/pf.conf'), dnctlFlushArgv()],
          reason: 'pf was enabled before the spike, so switching it off would '
              'be this harness changing a machine it did not shape — the '
              'teardown restores what was found, it does not impose a state');
      expect(directory.existsSync(), isFalse);
    });
  });

  // ---------------------------------------------------------------------
  // The kernel arms. One probe, declared once, carried into every group as a
  // named skip (RESEARCH Finding 13).
  // ---------------------------------------------------------------------
  final tc = await hasTc();
  final needsNetem = tc.available ? null : tc.reason;

  group('netem delay', () {
    test('makes a real loopback round trip measurably slower', () async {
      final connection = await _echoConnection();
      final before = await _roundTrip(connection.client, connection.echoes);

      await installNetem('lo', const NetemSpec(delay: _delay),
          registerTeardown: addTearDown);

      final after = await _roundTrip(connection.client, connection.echoes);
      final expected = loopbackRoundTripFor(_delay);
      expect(after - before, greaterThan(expected * 0.8),
          reason: 'the same connection round-tripped in '
              '${before.inMilliseconds} ms before the qdisc and '
              '${after.inMilliseconds} ms after; anything much under '
              '${expected.inMilliseconds} ms means the qdisc installed but is '
              'not on the path the socket takes, which is the failure mode '
              'that makes an OS-level suite look green while injecting '
              'nothing');
    });
  }, skip: needsNetem);

  group('netem loss 100%', () {
    test('blackholes an established connection, and it recovers on removal',
        () async {
      final connection = await _echoConnection();
      await _roundTrip(connection.client, connection.echoes);

      await installNetem('lo', const NetemSpec(lossPercent: 100),
          registerTeardown: addTearDown);

      connection.client.add(const [0x2a]);
      await expectLater(
        connection.echoes.first.timeout(const Duration(milliseconds: 1500)),
        throwsA(isA<TimeoutException>()),
        reason: 'a kernel blackhole drops the packet with no FIN and no RST — '
            'unlike the proxy blackhole, which reads the bytes and discards '
            'them at the stream layer',
      );

      await removeNetem('lo');
      await within(
        connection.echoes.first,
        'the blackholed byte arrived once the qdisc was removed, proving the '
            'connection was starved rather than killed',
        budget: const Duration(seconds: 15),
      );
    });
  }, skip: needsNetem);

  group('netem reorder', () {
    test('delivers loopback datagrams out of order', () async {
      await installNetem(
          'lo',
          const NetemSpec(delay: Duration(milliseconds: 30), reorderPercent: 50),
          registerTeardown: addTearDown);

      final exchange =
          await _sendDatagrams(settle: const Duration(seconds: 2));
      final received = exchange.received;

      expect(received.length, greaterThan(_datagrams ~/ 2),
          reason: 'reorder is not loss; most of the ${exchange.sent} sent '
              'datagrams must still arrive or this arm is measuring the wrong '
              'fault');
      final inversions = [
        for (var i = 1; i < received.length; i++)
          if (received[i] < received[i - 1]) i,
      ];
      expect(inversions, isNotEmpty,
          reason: 'arrival order was $received — no inversion means netem '
              'accepted the qdisc and delivered the stream in order anyway, '
              'and this is the one fault class a TCP-based harness cannot '
              'even see');
    });
  }, skip: needsNetem);

  group('netem duplicate', () {
    test('delivers loopback datagrams twice', () async {
      await installNetem('lo', const NetemSpec(duplicatePercent: 50),
          registerTeardown: addTearDown);

      final exchange =
          await _sendDatagrams(settle: const Duration(milliseconds: 500));

      expect(exchange.received.length, greaterThan(exchange.sent),
          reason: 'more packets came out than went in, which is the whole '
              'claim: ${exchange.sent} sent, ${exchange.received.length} '
              'received');
      expect(exchange.received.toSet().length,
          lessThan(exchange.received.length));
    });
  }, skip: needsNetem);

  // ---------------------------------------------------------------------
  // Teardown integrity. These two run in declaration order under the
  // package's `concurrency: 1`, and the second is the assertion about the
  // first (threat T-02-15).
  // ---------------------------------------------------------------------
  group('teardown integrity', () {
    test('a fresh install inherits nothing from the previous one', () async {
      await installNetem(
          'lo',
          const NetemSpec(delay: Duration(milliseconds: 20),
              duplicatePercent: 1),
          registerTeardown: addTearDown);
      expect(await netemShow('lo'), contains('duplicate'));

      await installNetem('lo', const NetemSpec(delay: Duration(milliseconds: 7)),
          registerTeardown: addTearDown);

      expect(await netemShow('lo'), isNot(contains('duplicate')),
          reason: 'this is the del-then-add discipline observed at the kernel '
              'rather than grepped in the source: Finding 12 measured both '
              'change and replace leaving the earlier parameter in place');
    });

    test('a test body that throws still gets its qdisc removed', () async {
      Future<void> body() async {
        await installNetem('lo', const NetemSpec(lossPercent: 100),
            registerTeardown: addTearDown);
        throw StateError('deliberate: the arm fails after the qdisc is on');
      }

      await expectLater(body(), throwsA(isA<StateError>()));
      expect(await netemInstalled('lo'), isTrue,
          reason: 'the removal is a teardown, so it has not run yet — if it '
              'had, the next arm would prove nothing');
    });

    test('...and the throwing body left no netem qdisc behind', () async {
      expect(await netemInstalled('lo'), isFalse,
          reason: 'the previous arm threw while a 100%-loss qdisc was '
              'installed on lo. A qdisc that survives that degrades every '
              'connection on the machine until somebody reboots, which is '
              'why the removal is registered at the moment the add succeeds '
              'and not at the end of the body');
    });
  }, skip: needsNetem);

  // ---------------------------------------------------------------------
  // The macOS spike. One attempt, not a suite: whether pf/dummynet shapes
  // 127.0.0.1 at all is unverified (RESEARCH Assumptions Log A1), and tests
  // planned against an unverified capability are tasks that cannot be
  // completed.
  // ---------------------------------------------------------------------
  final dnctl = await hasDnctl();
  final pfctl = await hasPfctl();
  final needsDummynet = !Platform.isMacOS
      ? 'dnctl/pf dummynet is macOS-only and this is '
          '${Platform.operatingSystem}, where tc netem carries the OS-level leg'
      : !dnctl.available
          ? dnctl.reason
          : !pfctl.available
              ? pfctl.reason
              : null;

  test('macOS dummynet shapes a loopback round trip', () async {
    final connection = await _echoConnection();
    final before = await _roundTrip(connection.client, connection.echoes);

    await installDummynetLoopbackDelay(
        perTraversalDelay: _delay, registerTeardown: addTearDown);

    final after = await _roundTrip(connection.client, connection.echoes);
    expect(after - before, greaterThan(loopbackRoundTripFor(_delay) * 0.8),
        reason: 'this single arm is the spike: pf on macOS ships with '
            '"set skip on lo0", and whether a dummynet rule can shape '
            '127.0.0.1 at all is the phase highest-risk unknown. A failure '
            'here is a legitimate recorded outcome — Linux netem carries the '
            'OS-level requirement either way');
  }, skip: needsDummynet);
}
