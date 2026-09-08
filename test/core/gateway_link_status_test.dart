import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

/// The reason strings below are **copied** out of
/// `packages/tfc_relay_client/lib/src/connection_supervisor.dart` at the line
/// numbers named on each one, not retyped. Three of them contain an
/// apostrophe, written in the client as `\'` inside single quotes; they are
/// double-quoted here so the apostrophe cannot be lost to an escape, and a
/// straightened one is the defect this whole vocabulary fails silently on.
///
/// The cross-package coupling arm — "is this string still a prefix of what a
/// *real* supervisor produces" — deliberately does not live here. A unit arm
/// fed a hand-copied string cannot tell a copied constant from a retyped one.
/// It is plan 15-04's, where a live supervisor produces the text.

/// `connection_supervisor.dart:483` — the dial produced no socket, and the
/// failure was not a handshake. The `OS Error` tail is what an integrator
/// pastes into a ticket, so it is carried here whole.
const String kDidNotAnswer =
    'the gateway did not answer: WebSocketChannelException: '
    'SocketException: Connection refused (OS Error: Connection refused, '
    'errno = 61), address = 10.50.10.11, port = 9444';

/// `connection_supervisor.dart:480-481`.
const String kCertificateNotTrusted =
    "the gateway's certificate was not trusted by this panel: "
    'WebSocketChannelException: HandshakeException: Handshake error in client '
    '(OS Error: CERTIFICATE_VERIFY_FAILED: unable to get local issuer '
    'certificate(handshake.cc:393))';

/// `connection_supervisor.dart:602-603` — the `-32003` `_stop` arm.
const String kCredentialRefused =
    "the gateway refused this panel's credential: "
    'this station token is not known to the gateway';

/// `connection_supervisor.dart:584-585` — the `-32004` `_stop` arm.
const String kVersionRefused =
    "the gateway refused this build's protocol version: "
    'this gateway speaks protocol 3, the panel offered 2';

/// `connection_supervisor.dart:933` — an established link letting go.
const String kTransportEnded = 'the transport ended';

/// `connection_supervisor.dart:952-955` — the half-open case.
const String kWentQuiet =
    'no frame of any kind for 9000 ms: the socket is open and the gateway '
    'has stopped speaking, which is the half-open case a close code never '
    'arrives for';

/// `connection_supervisor.dart:417`.
const String kDialFailed =
    'the dial failed: FormatException: Invalid port (at character 21)';

/// `connection_supervisor.dart:606`.
const String kHandshakeRefused =
    'the handshake was refused: the gateway is still starting up';

/// `connection_supervisor.dart:609`.
const String kDiedBeforeSnapshot =
    'the link died before the snapshot landed: Bad state: Stream closed';

/// Dialled by address — the rig's shape (`CN=10.50.10.11`, `SAN: IP Address`).
final Uri kByAddress = Uri.parse('wss://10.50.10.11:9444');

/// Dialled by name — the shape where the SAN is a candidate cause.
final Uri kByName = Uri.parse('wss://plc-gw.svn:9444');

void main() {
  // Every arm passes `elapsed:` explicitly. There is no clock read anywhere in
  // this file, which is what makes plan 15-07's golden frames constants rather
  // than a race against macOS CI's wall clock.

  group('the kinds a live client produces', () {
    test('a ready link reads connected and is not terminal', () {
      final report = describeGatewayLink(
        state: LinkState.ready,
        url: kByAddress,
        elapsed: Duration.zero,
      );
      expect(report.kind, GatewayLinkKind.connected);
      expect(report.terminal, isFalse);
    });

    // The operator standing at the card has just typed the address; the
    // headline has to be about the address they typed, not about "the server".
    test('a fresh dial inside the patience reads connecting and names the URL',
        () {
      final report = describeGatewayLink(
        state: LinkState.connecting,
        url: kByAddress,
        elapsed: const Duration(seconds: 2),
      );
      expect(report.kind, GatewayLinkKind.connecting);
      expect(report.terminal, isFalse);
      expect(report.headline, contains('10.50.10.11:9444'));
    });

    // The `OS Error` line is the only part of this a support engineer can act
    // on remotely, so `raw` carries the client's text whole and unedited.
    test('a dial that produced no socket reads unreachable, still retrying',
        () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kDidNotAnswer,
        url: kByAddress,
        elapsed: const Duration(seconds: 40),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.terminal, isFalse);
      expect(report.raw, kDidNotAnswer);
      expect(report.raw, contains('OS Error'));
    });

    // A certificate problem is not silence. Sending the operator to the cable
    // here is the wrong-end failure `_refusalReason`'s own doc exists to
    // prevent — this end is the pinned plant CA.
    test('a refused certificate sends the operator to the pinned CA, not the wire',
        () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kCertificateNotTrusted,
        url: kByAddress,
        elapsed: const Duration(seconds: 40),
      );
      expect(report.kind, GatewayLinkKind.untrustedCertificate);
      expect(report.terminal, isFalse);
      expect(report.detail, contains('plant CA pinned'),
          reason: 'the one-field flow removed the CA file and its path field; '
              'a sentence still naming "the CA root file configured above" '
              'would send the operator to a field that no longer exists');
      expect(report.raw, startsWith(GatewayLinkReasons.certificateNotTrusted));
    });

    // Terminal is the whole content of this one: the supervisor has given up,
    // and a panel that still says "connecting…" is lying about a state nobody
    // is going to leave without touching the config.
    test('a refused credential is terminal and says the panel has stopped', () {
      final report = describeGatewayLink(
        state: LinkState.down,
        stopReason: kCredentialRefused,
        url: kByAddress,
        elapsed: const Duration(seconds: 3),
      );
      expect(report.kind, GatewayLinkKind.credentialRefused);
      expect(report.terminal, isTrue);
      expect(report.detail, contains('stopped retrying'));
    });

    test('a refused protocol version is terminal', () {
      final report = describeGatewayLink(
        state: LinkState.down,
        stopReason: kVersionRefused,
        url: kByAddress,
        elapsed: const Duration(seconds: 3),
      );
      expect(report.kind, GatewayLinkKind.versionRefused);
      expect(report.terminal, isTrue);
    });
  });

  group('the unreachable fallback and its three sentences', () {
    // An established link dropping is not a dial that never landed. The word
    // `cable` is the assertion: five of the nine producers fall to this kind
    // and two of them must not send anybody to the switch cupboard.
    test('a dropped link says the connection ended, not to check the cable',
        () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kTransportEnded,
        url: kByAddress,
        elapsed: const Duration(seconds: 30),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.headline, contains('ended'));
      expect(report.detail, contains('reconnecting'));
      expect('${report.headline} ${report.detail}', isNot(contains('cable')));
    });

    // A half-open socket is the gateway's event loop, not the wire. A Veeam
    // snapshot froze the plant for everyone at once and no cable was pulled.
    test('a half-open socket does not send the operator to the cable', () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kWentQuiet,
        url: kByAddress,
        elapsed: const Duration(seconds: 30),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.detail, contains('rebuilding'));
      expect(report.detail, contains('stopped sending'));
      expect('${report.headline} ${report.detail}', isNot(contains('cable')));
    });

    // The three that genuinely mean the dial never landed keep the sentence
    // that names all three things to go and look at.
    test('the three dial-group reasons name the address, the port and the cable',
        () {
      for (final reason in [kDialFailed, kHandshakeRefused, kDiedBeforeSnapshot]) {
        final report = describeGatewayLink(
          state: LinkState.down,
          lastDownReason: reason,
          url: kByAddress,
          elapsed: const Duration(seconds: 30),
        );
        expect(report.kind, GatewayLinkKind.unreachable, reason: reason);
        expect(report.detail, contains('address'), reason: reason);
        expect(report.detail, contains('port'), reason: reason);
        expect(report.detail, contains('cable'), reason: reason);
        expect(report.raw, reason);
      }
    });

    // Widening the prefix match is how a programming error in the client
    // starts being reported as a plant condition — so anything unrecognised
    // lands here, whole, and nothing throws.
    test('a reason nobody wrote yet still produces a report, carried verbatim',
        () {
      const unknown = 'a thing nobody wrote yet';
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: unknown,
        url: kByAddress,
        elapsed: const Duration(seconds: 30),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.terminal, isFalse);
      expect(report.raw, unknown);
    });
  });

  group('the SAN hint', () {
    // Rig FIND-B's other half. On an address dial the name is not a candidate
    // cause, and a hint that is always shown is a hint nobody reads.
    test('an address dial gets no SAN hint anywhere in the report', () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kCertificateNotTrusted,
        url: kByAddress,
        elapsed: const Duration(seconds: 30),
      );
      expect(report.sanHint, isNull);
      expect(
        '${report.headline} ${report.detail}'.toLowerCase(),
        isNot(contains('subject-alternative')),
      );
    });

    // The rig's leaf carries `IP:10.50.10.11` and no DNS name, so an operator
    // who typed a hostname fails TLS with a message about *trust* — the wrong
    // end. This is the sentence that puts them at the right one.
    test('a hostname dial names the subject-alternative name as a candidate',
        () {
      final report = describeGatewayLink(
        state: LinkState.down,
        lastDownReason: kCertificateNotTrusted,
        url: kByName,
        elapsed: const Duration(seconds: 30),
      );
      expect(report.sanHint, isNotNull);
      expect(report.sanHint, contains('subject-alternative name'));
      expect(report.sanHint, contains('plc-gw.svn'));
    });
  });

  group('the patience window', () {
    test('inside the patience the report is still connecting', () {
      final report = describeGatewayLink(
        state: LinkState.connecting,
        url: kByAddress,
        elapsed: const Duration(seconds: 14),
      );
      expect(report.kind, GatewayLinkKind.connecting);
    });

    // "Never an indefinite spinner" is this arm. Past the window the panel
    // stops pretending and says what it knows: how long, and at what address.
    test('past the patience with no reason yet, it says so with the elapsed time',
        () {
      final report = describeGatewayLink(
        state: LinkState.connecting,
        url: kByAddress,
        elapsed: const Duration(seconds: 16),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
      expect(report.terminal, isFalse);
      final said = '${report.headline} ${report.detail}';
      expect(said, contains('10.50.10.11:9444'));
      expect(said, contains('16 s'));
    });

    // F-6. There is no `everReady` and no first-attempt timestamp in the
    // client, so the window is anchored at first *observation* — which means
    // an operator walking to a panel that has been broken all shift would be
    // told a fresh fifteen seconds unless the reason short-circuits it first.
    test('an existing lastDownReason short-circuits the patience entirely', () {
      final report = describeGatewayLink(
        state: LinkState.connecting,
        lastDownReason: kCertificateNotTrusted,
        url: kByAddress,
        elapsed: const Duration(seconds: 1),
      );
      expect(report.kind, GatewayLinkKind.untrustedCertificate);
      expect(report.kind, isNot(GatewayLinkKind.connecting));
    });

    test('an existing stopReason short-circuits the patience entirely', () {
      final report = describeGatewayLink(
        state: LinkState.connecting,
        stopReason: kCredentialRefused,
        url: kByAddress,
        elapsed: const Duration(seconds: 1),
      );
      expect(report.kind, GatewayLinkKind.credentialRefused);
      expect(report.terminal, isTrue);
    });

    // Named, so the widget, the golden and the provider all mean the same
    // fifteen seconds; overridable, so a test does not spend them.
    test('the patience is fifteen seconds and is overridable per call', () {
      expect(kGatewayFirstConnectPatience, const Duration(seconds: 15));
      final report = describeGatewayLink(
        state: LinkState.connecting,
        url: kByAddress,
        elapsed: const Duration(seconds: 3),
        patience: const Duration(seconds: 2),
      );
      expect(report.kind, GatewayLinkKind.unreachable);
    });
  });

  // ---------------------------------------------------------------------
  // The kind no live client can produce, because there is no live client.
  //
  // `describeGatewayLink` cannot describe this case: with nothing built there
  // is no `LinkState`, no `lastDownReason` and no elapsed time, so a caller
  // forced through that entry point would have to invent all three. The
  // socket-level half of these arms — that a real missing file really does
  // arrive here — is `test/providers/gateway_link_test.dart`'s; these pin the
  // mapping, which is the part a unit arm can own.
  // ---------------------------------------------------------------------
  group('a transport that could not be built', () {
    const String kPath = '/home/centroid/relay_config/pki/plant-root.pem';
    const String kThrew = "PathNotFoundException: Cannot open file, path = "
        "'$kPath' (OS Error: No such file or directory, errno = 2)";

    test('a failure that named a file names it back, and is terminal', () {
      final report = describeGatewayLinkFailure(
        url: kByAddress,
        failure: const GatewayLinkBuildFailure(raw: kThrew, path: kPath),
      );

      expect(report.kind, GatewayLinkKind.notBuilt);
      expect(report.terminal, isTrue,
          reason: 'terminal in the strongest sense this surface has: there is '
              'no retry loop to have stopped, because none was started');
      expect(report.detail, contains(kPath));
      expect(report.raw, kThrew,
          reason: 'the ticket field carries the panel\'s own error whole and '
              'unedited, the way it carries the gateway\'s on every other '
              'kind');
      expect(report.sanHint, isNull,
          reason: 'nothing was dialled, so no certificate was presented and '
              'the name is not a candidate cause of anything');
    });

    test('and the sentence does not send anybody to the cable', () {
      final report = describeGatewayLinkFailure(
        url: kByAddress,
        failure: const GatewayLinkBuildFailure(raw: kThrew, path: kPath),
      );
      final said = '${report.headline} ${report.detail}';

      // The whole reason this is not `unreachable`. That kind's detail reads
      // "Check the address and the port above, that the gateway is running,
      // and the cable and switch between this panel and it" — which is the
      // wrong end of the wire for a file on this station's own disk, and the
      // wrong-end failure the entire vocabulary exists to prevent.
      expect(said, isNot(contains('cable')));
      expect(said, isNot(contains('switch')));
      expect(said, contains('restart'),
          reason: 'transport is restart-to-apply, so fixing the path is only '
              'half of what the operator has to do');
    });

    test('a failure that named no file falls to the wider sentence', () {
      const String tls = 'TlsException: Failure trusting builtin roots '
          '(OS Error: BAD_PKCS12_DATA(pkcs8_x509.cc:559), errno = 318767204)';
      final report = describeGatewayLinkFailure(
        url: kByAddress,
        failure: const GatewayLinkBuildFailure(raw: tls),
      );

      expect(report.kind, GatewayLinkKind.notBuilt);
      expect(report.terminal, isTrue);
      expect(report.raw, tls);
      // Not vacuous: it still tells the operator where to go, it just cannot
      // point at one filename.
      expect(report.detail, contains('gateway address'));
      expect(report.detail, contains('pinned plant CA'));
    });

    test('an empty path is the same as no path, not a blank filename', () {
      // `FileSystemException.path` is nullable AND can be the empty string.
      // A sentence reading "could not open ." is worse than the wider one.
      final report = describeGatewayLinkFailure(
        url: kByAddress,
        failure: const GatewayLinkBuildFailure(raw: 'boom', path: ''),
      );
      expect(report.detail, contains('pinned plant CA'));
    });

    test('a URL that will not parse renders as nothing rather than as a '
        'blank endpoint', () {
      // `gatewayLinkProvider` passes `Uri()` when the configured URL does not
      // parse — which is one of the failures being reported. Neither sentence
      // for this kind may interpolate it.
      const failure = GatewayLinkBuildFailure(raw: kThrew, path: kPath);
      final unparseable = describeGatewayLinkFailure(
        url: Uri(),
        failure: failure,
      );
      final ordinary =
          describeGatewayLinkFailure(url: kByAddress, failure: failure);

      // Stronger than a `isNot(contains(' '))` sniff, and it is the property:
      // the two sentences for this kind are the same sentences whatever the
      // URL is, so an empty one cannot render as a hole in the middle of a
      // line an operator is reading.
      expect(unparseable.headline, ordinary.headline);
      expect(unparseable.detail, ordinary.detail);
      expect(unparseable.detail, contains(kPath));
    });

    // **This arm exists because a sabotage turned nothing red.** Splicing
    // `failure.raw` straight into `detail` left every other arm in this file
    // and in `test/providers/gateway_link_test.dart` green — including the
    // provider arm named "its contents never reach the prose". The reason is
    // measurable: that arm drives a CA file that is present but is not a PEM,
    // and the real `TlsException` reads "Failure trusting builtin roots (OS
    // Error: BAD_PKCS12_DATA...)" without echoing one byte of the file. So the
    // arm could not fail, whatever the mapper did with the text.
    //
    // Here the leak is put where it can be seen: a `raw` that provably carries
    // something which must not reach the two lines an operator reads across a
    // room. The general property is asserted as well as the sentinel, because
    // the next leak will not be spelled DO-NOT-LOG.
    test('the failure\'s own text never becomes the operator\'s two lines',
        () {
      const String sentinel = 'ST101-TOKEN-3f9a2b7c-DO-NOT-LOG';
      const String leaky = "FileSystemException: Cannot open file, path = "
          "'$kPath' (OS Error: No such file or directory, errno = 2) while "
          'presenting $sentinel';
      final report = describeGatewayLinkFailure(
        url: kByAddress,
        failure: const GatewayLinkBuildFailure(raw: leaky, path: kPath),
      );

      expect(report.headline, isNot(contains(sentinel)));
      expect(report.detail, isNot(contains(sentinel)));
      // The general form, and the one a future leak trips over: `detail` is
      // built out of this file's own constants and the operator's own path,
      // so it can never contain the failure text whole.
      expect(report.detail, isNot(contains(leaky)));
      // The distinction, stated: the paste-into-a-ticket field may carry it,
      // exactly as it does for the gateway's `-32003` refusal.
      expect(report.raw, contains(sentinel));
      // Not vacuous: the sentence the operator needs is still complete.
      expect(report.detail, contains(kPath));
    });

    test('userinfo in the configured URL is never rendered here either', () {
      final leaky = Uri.parse('wss://user:secret@10.50.10.11:9444');
      final report = describeGatewayLinkFailure(
        url: leaky,
        failure: const GatewayLinkBuildFailure(raw: kThrew, path: kPath),
      );
      final said = '${report.headline} ${report.detail}';
      expect(said, isNot(contains('secret')));
      expect(said, isNot(contains('user:')));
      expect(said, isNot(contains('@')));
      // Not vacuous: the sentence an operator reads is still there in full.
      expect(said, contains(kPath));
    });
  });

  group('the report never repeats the credential', () {
    // The client already refuses to splice `config.token` into `stopReason`
    // (`connection_supervisor.dart:596-600`) because a panel stands where
    // anybody can read it. This file must not undo that on the way to a
    // screen. `raw` is exempt on purpose: it is the paste-into-a-ticket field,
    // it is not rendered as prose, and it carries only what the gateway said.
    test('a token in the gateway\'s own message never reaches the prose', () {
      const leaky = "the gateway refused this panel's credential: "
          'ST101-TOKEN-DO-NOT-LOG is not a known station';
      final report = describeGatewayLink(
        state: LinkState.down,
        stopReason: leaky,
        url: kByAddress,
        elapsed: const Duration(seconds: 3),
      );
      expect(report.kind, GatewayLinkKind.credentialRefused);
      expect(report.headline, isNot(contains('ST101-TOKEN-DO-NOT-LOG')));
      expect(report.detail, isNot(contains('ST101-TOKEN-DO-NOT-LOG')));
      // The distinction, stated: the ticket field may carry it.
      expect(report.raw, contains('ST101-TOKEN-DO-NOT-LOG'));
    });

    // A URL with userinfo is a credential in a preferences row, and rendering
    // it back is how it ends up in a photograph of a panel.
    test('userinfo in the dialled URL is never rendered', () {
      final leaky = Uri.parse('wss://user:secret@10.50.10.11:9444');
      for (final report in [
        describeGatewayLink(
          state: LinkState.connecting,
          url: leaky,
          elapsed: const Duration(seconds: 2),
        ),
        describeGatewayLink(
          state: LinkState.down,
          lastDownReason: kDidNotAnswer,
          url: leaky,
          elapsed: const Duration(seconds: 30),
        ),
        describeGatewayLink(
          state: LinkState.ready,
          url: leaky,
          elapsed: Duration.zero,
        ),
      ]) {
        final said = '${report.headline} ${report.detail}';
        expect(said, isNot(contains('secret')), reason: '${report.kind}');
        expect(said, isNot(contains('user:')), reason: '${report.kind}');
        expect(said, isNot(contains('@')), reason: '${report.kind}');
        // Not vacuous: the address itself is still there to be read.
        expect(said, contains('10.50.10.11:9444'), reason: '${report.kind}');
      }
    });
  });
}
