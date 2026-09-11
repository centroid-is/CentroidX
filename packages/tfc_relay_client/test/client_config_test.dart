/// Every client timing number has one home, and the combinations that cannot
/// work are refused at construction.
///
/// Source: 04-RESEARCH Finding 8 measured this transport at a **50.0 ms mean
/// round trip over 50 `ping` calls**, quantised to the server's fan-out
/// period, which itself runs 50–100 ms. A deadline anywhere near that floor
/// fires on a healthy link, and on the write path a fired deadline is not an
/// error the operator can act on — it resolves `WriteUnknown`. A plant where
/// every ordinary write comes back "unknown" is a plant where nobody trusts
/// the screen, which is the one thing this product sells.
///
/// Source: 04-CONTEXT post-research ruling — the freshness deadline is
/// **configured, default 3 s**, never derived from the transport period. Three
/// times a 50 ms period is 150 ms, and a GC pause would grey the whole plant.
///
/// Source: 06-RESEARCH §A.3 measured a panel dialling `wss://` on the system
/// trust store failing every handshake against a private CA with the same
/// opaque `CERTIFICATE_VERIFY_FAILED` a real impostor produces — so the
/// combination is refused at construction rather than once per attempt, and
/// the pinned root is a **file path** (orchestrator ruling OQ4) because
/// installing it in the OS trust store would mean trusting that store.
///
/// Source: STACK rejected `web_socket_client` for an infinite backoff loop, so
/// a cap above 30 s is refused rather than merely discouraged: a panel that
/// backs off to ten minutes is a panel the operator reboots.
library;

import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:test/test.dart';

void main() {
  group('ClientConfig defaults', () {
    test('the researched numbers are what you get for free', () {
      final config = ClientConfig();

      expect(config.controlDeadline, const Duration(seconds: 1),
          reason: 'a control-plane call that never returns leaves the panel '
              'showing a connecting spinner forever');
      expect(config.writeDeadline, const Duration(seconds: 2),
          reason: 'a write with no deadline hangs the operator on a button '
              'press instead of telling them the outcome is unknown');
      expect(config.freshnessDeadline, const Duration(seconds: 3),
          reason: 'the design band is 2-5 s; a value outside it either greys '
              'a healthy plant or hides a dead link');
      expect(config.backoffBase, const Duration(milliseconds: 250));
      expect(config.backoffCap, const Duration(seconds: 30));
      expect(config.implausibleClockThreshold, const Duration(minutes: 5));
      expect(config.deadlineFloor, const Duration(milliseconds: 500));
    });

    test('the floor is the measured round trip rounded up, not a guess', () {
      expect(ClientConfig.defaultDeadlineFloor,
          const Duration(milliseconds: 500),
          reason: 'a bare round trip on this transport is one server period; '
              'a floor under it makes a healthy link look broken');
      expect(ClientConfig.maxBackoffCap, const Duration(seconds: 30),
          reason: 'an unbounded cap is the infinite-backoff bug that got '
              'web_socket_client rejected');
    });
  });

  group('a deadline under the floor is refused, naming the floor', () {
    test('writeDeadline under the floor names the field, value and floor', () {
      expect(
        () => ClientConfig(writeDeadline: const Duration(milliseconds: 200)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            allOf(
              contains('writeDeadline'),
              contains('200 ms'),
              contains('500 ms'),
            ),
          ),
        ),
        reason: 'a deadline under one round trip turns every write on a '
            'healthy link into a false unknown, and the message has to say '
            'which number and which bound so the operator who set it can '
            'undo it',
      );
    });

    test('controlDeadline under the floor is refused by name', () {
      expect(
        () => ClientConfig(controlDeadline: const Duration(milliseconds: 100)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('controlDeadline'), contains('100 ms')),
        )),
        reason: 'a subscribe that times out before the server can answer '
            'reconnects forever and never shows a value',
      );
    });

    test('freshnessDeadline under the floor is refused by name', () {
      expect(
        () =>
            ClientConfig(freshnessDeadline: const Duration(milliseconds: 150)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('freshnessDeadline'), contains('150 ms')),
        )),
        reason: 'three times the transport period is 150 ms, and a single GC '
            'pause at that setting greys the whole plant',
      );
    });

    test('exactly at the floor is allowed', () {
      final config =
          ClientConfig(writeDeadline: const Duration(milliseconds: 500));
      expect(config.writeDeadline, const Duration(milliseconds: 500),
          reason: 'the floor is a floor, not an exclusive bound; refusing it '
              'would make the documented minimum unusable');
    });
  });

  group('the floor itself is injectable, on purpose and greppably', () {
    test('lowering deadlineFloor admits a sub-floor write deadline', () {
      final config = ClientConfig(
        deadlineFloor: const Duration(milliseconds: 10),
        writeDeadline: const Duration(milliseconds: 100),
      );

      expect(config.writeDeadline, const Duration(milliseconds: 100),
          reason: "truncated_write_test's polarity flip only means something "
              'if the write deadline can fire inside the case\'s own budget; '
              'a hard floor would make the flip untestable');
      expect(config.deadlineFloor, const Duration(milliseconds: 10));
    });

    test('a raised floor refuses a default that was fine before', () {
      expect(
        () => ClientConfig(deadlineFloor: const Duration(seconds: 5)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('controlDeadline'), contains('5000 ms')),
        )),
        reason: 'the floor is checked against every deadline including the '
            'defaults, so a floor raised past them fails loudly at '
            'construction instead of quietly at 3 a.m.',
      );
    });

    test('a non-positive floor is refused', () {
      expect(
        () => ClientConfig(deadlineFloor: Duration.zero),
        throwsA(isA<ArgumentError>()),
        reason: 'a zero floor disables the only check standing between a '
            'typo and a plant full of false unknowns',
      );
    });
  });

  group('backoff bounds', () {
    test('a cap above 30 s is refused', () {
      expect(
        () => ClientConfig(backoffCap: const Duration(minutes: 2)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('backoffCap'), contains('30000 ms')),
        )),
        reason: 'a panel that backs off past half a minute looks dead to the '
            'operator, who power-cycles it instead of waiting',
      );
    });

    test('a base above the cap is refused', () {
      expect(
        () => ClientConfig(
          backoffBase: const Duration(seconds: 20),
          backoffCap: const Duration(seconds: 5),
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          contains('backoffBase'),
        )),
        reason: 'a base over the cap means the very first retry is already '
            'clamped, so the schedule is a constant and the herd re-forms',
      );
    });

    test('a non-positive base is refused', () {
      expect(
        () => ClientConfig(backoffBase: Duration.zero),
        throwsA(isA<ArgumentError>()),
        reason: 'a zero base is a reconnect loop with no pause, which is a '
            'denial of service the panel commits against its own gateway',
      );
    });

    test('a non-positive implausible-clock threshold is refused', () {
      expect(
        () => ClientConfig(implausibleClockThreshold: Duration.zero),
        throwsA(isA<ArgumentError>()),
        reason: 'a zero threshold warns about clock skew on every hello, and '
            'a warning that is always on is a warning nobody reads',
      );
    });
  });

  group('the hold-to-run cadence and the deadman ratio', () {
    test("the default hold cadence and ratio multiply out to the plant's one "
        'second', () {
      final config = ClientConfig();

      expect(config.holdPulsePeriod, const Duration(milliseconds: 100),
          reason: 'the deadman is fed at 10 Hz; a slower cadence spends the '
              "PLC's tolerance budget on fewer pulses and a faster one buys "
              'nothing the operator can feel');
      expect(config.holdMissedPulsesBeforeStop, 10);
      // The product, not the constant. A change to either factor moves the
      // number the PLC's TON preset was chosen against, and the whole point of
      // spelling the deadman as a ratio is that the two cannot drift apart
      // silently.
      expect(config.holdPulsePeriod * config.holdMissedPulsesBeforeStop,
          const Duration(seconds: 1),
          reason: 'the cadence and the ratio no longer multiply out to the one '
              'second the plant was configured for, so the panel and the PLC '
              'now disagree about how long a machine may coast after the '
              'operator lets go — and only the PLC stops it');
      expect(config.holdDeadman, const Duration(seconds: 1),
          reason: 'holdDeadman is the derived answer to "how long until the '
              'machine stops"; a value other than the product means it is '
              'being stored somewhere instead of computed, which is how two '
              'numbers that must agree stop agreeing');
    });

    test('the default config constructs, because a cadence is not a deadline',
        () {
      // The named regression case for the phase's most likely mechanical
      // mistake (05-RESEARCH "Traps for the executor" #1). `_atLeastFloor`
      // rejects anything under `deadlineFloor`, which defaults to 500 ms; the
      // hold cadence is 100 ms, one fifth of it.
      final config =
          ClientConfig(holdPulsePeriod: const Duration(milliseconds: 100));

      expect(config.holdPulsePeriod, const Duration(milliseconds: 100),
          reason: 'a 100 ms cadence against the default 500 ms deadline floor '
              'threw at construction, which means the hold cadence was routed '
              'through the deadline-floor validator. A cadence is not a '
              'deadline: nothing waits on one pulse, and a dropped one costs '
              'nothing the next one 100 ms later does not fix. Routed that '
              'way, `ClientConfig()` with no arguments throws — so the panel '
              'does not come up at all, and every screen in the plant is dark '
              'at shift start');
      expect(config.deadlineFloor, const Duration(milliseconds: 500),
          reason: 'the floor is still the researched 500 ms, so the case above '
              'was judged against the default and not against a floor the case '
              'quietly lowered for itself');
    });

    test('a zero cadence is refused by name', () {
      expect(
        () => ClientConfig(holdPulsePeriod: Duration.zero),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('holdPulsePeriod'), contains('0 ms')),
        )),
        reason: 'a zero cadence is a timer that fires as fast as the event '
            'loop will let it, which floods the socket the deadman is fed '
            'over and starves everything else on the panel',
      );
    });

    test('a negative cadence is refused by name', () {
      expect(
        () => ClientConfig(holdPulsePeriod: const Duration(milliseconds: -100)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('holdPulsePeriod'), contains('-100 ms')),
        )),
        reason: 'a negative cadence disables the feed, so the button lights '
            'and the machine never jogs',
      );
    });

    test('fewer than three missed pulses inverts the tolerance decision', () {
      expect(
        () => ClientConfig(holdMissedPulsesBeforeStop: 2),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('holdMissedPulsesBeforeStop'), contains('2')),
        )),
        reason: 'at two missed pulses a single Wi-Fi retransmit stops the '
            'machine mid-jog. The plant chose the opposite: up to a second of '
            'coasting is accepted so that a panel hiccup does not drop the '
            'output, and a ratio under three turns that decision into its '
            'opposite while still looking like a safety tightening',
      );
    });

    test('exactly three missed pulses is allowed', () {
      final config = ClientConfig(holdMissedPulsesBeforeStop: 3);

      expect(config.holdMissedPulsesBeforeStop, 3,
          reason: 'three is the documented bound, and a bound that refuses its '
              'own minimum is a bound nobody can set');
      expect(config.holdDeadman, const Duration(milliseconds: 300),
          reason: 'the deadman follows the ratio it was given rather than the '
              'default it was not, or it is not derived at all');
    });

    test('the deadman follows an injected cadence rather than a constant', () {
      final config = ClientConfig(
        holdPulsePeriod: const Duration(milliseconds: 50),
        holdMissedPulsesBeforeStop: 20,
      );

      expect(config.holdDeadman, const Duration(seconds: 1),
          reason: 'a panel on a slow link is fed at a cadence of its own, and '
              'the deadman it reports has to be that cadence times that ratio '
              '— a hard-coded second would tell the integrator the wrong '
              'number for every panel that is not on the default');
    });
  });

  group('the station credential', () {
    test('a panel with no credential configured still constructs', () {
      final config = ClientConfig();

      expect(config.token, isNull,
          reason: 'null is the shipped default and every fixture in this '
              'workspace depends on it: a gateway running the permissive '
              'validator is what the whole existing suite dials. A default of '
              'anything else — an empty string most of all — would send a '
              'credential the integrator never configured, and the day a real '
              'token file is mounted every panel would be refused at once');
    });

    test('the credential is carried verbatim, not judged here', () {
      // Deliberately short and odd-looking. A length or shape rule in
      // `ClientConfig` would be a second opinion about a secret whose only
      // real judge is the gateway, and a panel that refuses to construct
      // because its mounted credential looks wrong is a dark screen at shift
      // start instead of a refusal an operator can read.
      final config = ClientConfig(token: 'x');

      expect(config.token, 'x',
          reason: 'the panel presents what it was mounted with. A config that '
              'trimmed, padded or rejected the credential would turn a '
              'provisioning mistake into a fault that reproduces nowhere, '
              'because the string on disk and the string on the wire would no '
              'longer be the same string');
    });
  });

  group('the pinned root a wss panel cannot be built without', () {
    /// A path nothing in this group reads.
    ///
    /// `ClientConfig` is pure data — no I/O, no clock — so a constructor that
    /// stat'd the mount point would refuse on a station whose NFS mount comes
    /// up a second after the panel does, which is a dark screen at shift start
    /// for a certificate that is fine.
    const rootPath = '/etc/relay/root.pem';

    test('a panel dialling wss with no pinned root is refused at construction',
        () {
      expect(
        () => RemoteStateMan(
          uri: Uri.parse('wss://relay.svn.local:8443/'),
          config: ClientConfig(),
        ),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('wss'))
            .having((e) => '$e', 'message', contains('rootCertPath'))),
        reason: 'a panel dialling wss on the system trust store fails every '
            'handshake against a private CA, and the message it fails with is '
            'byte-identical to the one a real impostor produces (06-RESEARCH '
            '§A.3 row 6). The integrator standing at the panel is then '
            'debugging an attack that is not happening. Refusing here says '
            'the true thing once, at construction, naming the field that is '
            'missing',
      );
    });

    test('the same address is constructible once a root is pinned', () {
      expect(
        () => ClientConfig(tls: ClientTlsConfig(rootCertPath: rootPath))
            .checkDialable(Uri.parse('wss://relay.svn.local:8443/')),
        returnsNormally,
        reason: 'the refusal is about the missing root and nothing else — a '
            'rule that refused wss outright would take the encrypted pipe '
            'away from the plant it was built for',
      );
    });

    test('a plaintext panel needs no pinned root', () {
      expect(
        () => ClientConfig().checkDialable(Uri.parse('ws://127.0.0.1:8080/')),
        returnsNormally,
        reason: 'every fixture in this workspace dials ws:// with no TLS at '
            'all; a rule that reached them would be a rewrite of the suite '
            'wearing the clothes of a security check',
      );
    });

    test('a pinned root on a plaintext dial is refused', () {
      expect(
        () => ClientConfig(tls: ClientTlsConfig(rootCertPath: rootPath))
            .checkDialable(Uri.parse('ws://10.104.29.71:8080/')),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('ws://10.104.29.71:8080'))
            .having((e) => '$e', 'message', contains('plaintext'))),
        reason: 'RemoteStateMan builds the pinned SecurityContext and the '
            'HttpClient from this root and hands them to a dial that never '
            'consults them. The configuration reads as encrypted and the link '
            'is not, which is the failure checkDialable was written to '
            'prevent running in the other direction',
      );
    });

    test('a station credential on a plaintext dial is refused', () {
      expect(
        () => ClientConfig(token: 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3')
            .checkDialable(Uri.parse('ws://10.104.29.71:8080/')),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('clear'))
            .having((e) => '$e', 'message',
                contains('allowTokenOverPlaintext'))),
        reason: 'ConnectionSupervisor puts config.token on the hello frame '
            'unconditionally, so a credential that grants operate on the '
            'plant\'s PLCs crosses the LAN in the clear once per reconnect '
            'for as long as the panel runs. Anybody with a span port has a '
            'working credential. Design §7.1 presents ServerConfig.tls and '
            'ServerConfig.auth as independently nullable, which is an '
            'explicit invitation to turn the token file on before TLS',
      );
    });

    test('the credential is not refused when it is what a fixture is for', () {
      expect(
        () => ClientConfig(
          token: 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3',
          allowTokenOverPlaintext: true,
        ).checkDialable(Uri.parse('ws://127.0.0.1:8080/')),
        returnsNormally,
        reason: 'the credential path has to stay exercisable over plaintext '
            'loopback — that is how auth_refusal_test drives the refusal legs '
            'and how Phase 7 will drive them through the fault proxy. The '
            'opt-in is explicit and greppable, which is the difference '
            'between a fixture and a deployment',
      );
    });

    test('the escape hatch does not excuse a pinned root', () {
      expect(
        () => ClientConfig(
          tls: ClientTlsConfig(rootCertPath: rootPath),
          allowTokenOverPlaintext: true,
        ).checkDialable(Uri.parse('ws://127.0.0.1:8080/')),
        throwsA(isA<ArgumentError>()),
        reason: 'the flag says one thing — that this panel deliberately sends '
            'its credential in the clear. A root that is never consulted is a '
            'different mistake and has no reason to be forgiven by it',
      );
    });

    test('an empty root path is refused at construction', () {
      expect(
        () => ClientTlsConfig(rootCertPath: ''),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('rootCertPath'))),
        reason: 'an empty path reaches SecurityContext as the current '
            'directory and fails with a message about a directory nobody '
            'configured, one handshake at a time, forever',
      );
    });

    test('the pinned root is a path or public PEM text, never raw bytes', () {
      final source = File('lib/src/client_config.dart');
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text, so it must be '
              'run from the package root the CI step sets as its '
              'working-directory');

      final code = source.readAsStringSync();
      expect(code, contains('final String? rootCertPath;'),
          reason: 'the path variant survives: a station provisioned by mount '
              'keeps dialling, and the field staying a String path is what '
              'keeps the SEC-01 sweep and this class agreeing about where '
              'key material lives');
      expect(code, contains('final String? rootCertPem;'),
          reason: 'the material variant is a *PEM string* — public '
              'certificate text, the same shape OpcUAConfig carries — never '
              'an opaque byte field. A CA root is what the gateway hands '
              'anyone who asks; the discipline that stays absolute is about '
              'keys, and no key has a field here');
      expect(code, isNot(contains('List<int>')),
          reason: 'a config that can hold opaque bytes is a config that '
              'eventually holds key material — in a preferences row, a log '
              'line or a crash dump. PEM text is greppable and visibly '
              'public; a byte field is neither');
    });

    test('a dial carries a bound by default', () {
      expect(ClientConfig().connectTimeout, const Duration(seconds: 10),
          reason: 'measured (06-RESEARCH §C.4): an unreachable address takes '
              '75 s to fail on macOS. Unbounded, one attempt outlives the '
              'whole backoff schedule the operator can see, and a panel '
              'behind a firewall that drops SYNs looks like a panel that has '
              'stopped trying');
    });

    test('a non-positive dial bound is refused', () {
      expect(
        () => ClientConfig(connectTimeout: Duration.zero),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('connectTimeout'))),
        reason: 'zero would abort every dial before the handshake it is '
            'guarding could finish, which is a panel that never connects at '
            'all rather than one that connects slowly',
      );
    });
  });

  group('the heartbeat floor', () {
    test('the default floor is one second', () {
      expect(ClientConfig().heartbeatFloor, const Duration(seconds: 1),
          reason: 'the floor is what the pump falls back on against a gateway '
              'that advertises no deadline, and it is the ceiling on how fast '
              'a gateway can talk this panel into beating. One second is '
              'already sixty frames a minute per panel and is faster than any '
              'deadline a sane gateway would set; the alternative — no floor '
              'and no advertisement — is a panel that never beats, which is '
              'the reaping this knob exists to end');
    });

    test('a heartbeat floor under the deadline floor constructs, because a '
        'cadence is not a deadline', () {
      // The same regression case the hold cadence has, for the same mistake,
      // written out again because the mistake is mechanical: `_atLeastFloor`
      // is right there beside `_positive` in the constructor and it is the
      // wrong one. A gate case that has to watch several beats inside its own
      // budget sets this to 40 ms; routed through the deadline validator that
      // is an ArgumentError, and the only way back is to lower `deadlineFloor`
      // in the same breath — which changes what every *deadline* in the case
      // means, to buy a cadence.
      final config = ClientConfig(heartbeatFloor: const Duration(milliseconds: 40));

      expect(config.heartbeatFloor, const Duration(milliseconds: 40),
          reason: 'a 40 ms heartbeat floor against the default 500 ms deadline '
              'floor threw at construction, so the cadence was routed through '
              'the deadline-floor validator. Nothing waits on one beat and a '
              'dropped one costs nothing the next one covers');
      expect(config.deadlineFloor, ClientConfig.defaultDeadlineFloor,
          reason: 'the floor is still the researched default, so the case '
              'above was judged against it rather than against one the case '
              'quietly lowered for itself');
    });

    test('a zero heartbeat floor is refused by name', () {
      expect(
        () => ClientConfig(heartbeatFloor: Duration.zero),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('heartbeatFloor'), contains('0 ms')),
        )),
        reason: 'zero would arm the pump\'s periodic timer at Duration.zero, '
            'which is a beat every turn of the event loop — one panel '
            'flooding the single gateway that serves every screen in the '
            'factory, on the one path that runs whenever the link is healthy',
      );
    });

    test('a negative heartbeat floor is refused by name', () {
      expect(
        () => ClientConfig(heartbeatFloor: const Duration(milliseconds: -100)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('heartbeatFloor'), contains('-100 ms')),
        )),
        reason: 'a negative floor would let a gateway advertising a very '
            'short deadline drive the period below zero, and a panel that '
            'never beats is a panel the reaper takes once a deadline for ever',
      );
    });
  });

  group('the freshness deadline cannot learn a transport period', () {
    test('no field or parameter of the config is derived from the server '
        'cadence', () {
      final source = File('lib/src/client_config.dart');
      expect(source.existsSync(), isTrue,
          reason: 'this case reads the implementation as text, so it must be '
              'run from the package root the CI step sets as its '
              'working-directory');

      final code = source
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('///'))
          .join('\n')
          .toLowerCase();

      expect(code, isNot(contains('tick')),
          reason: 'the moment the config can read the server cadence, someone '
              'will multiply it by three and ship a 150 ms freshness deadline '
              'that greys the plant on a GC pause; the deadline is configured '
              'and the ratio is asserted against an injected period instead');
    });
  });
}
