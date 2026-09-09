import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_link_status.dart' show isIpLiteralHost;
import 'package:tfc_dart/core/preferences.dart';

/// Stands in for the plant CA. Not a parseable certificate — nothing in
/// `GatewayConfig` parses it; parsing happens where the pin is consumed
/// (`RemoteStateMan`) and where the fingerprint is computed
/// (`gateway_trust.dart`), each with tests of its own.
const String _fakePem = '-----BEGIN CERTIFICATE-----\n'
    'dGhlIHBsYW50IENBLCBhcyBhcHByb3ZlZCBieSB0aGUgb3BlcmF0b3I=\n'
    '-----END CERTIFICATE-----\n';

void main() {
  group('GatewayConfig persistence', () {
    test('a station that has never been configured runs direct', () async {
      final prefs = InMemoryPreferences();
      expect(await readGatewayConfig(prefs), GatewayConfig.defaults);
      expect(GatewayConfig.defaults.mode, TransportMode.direct);
      expect(GatewayConfig.defaults.isGateway, isFalse);
    });

    test('round-trips every field through preferences', () async {
      final prefs = InMemoryPreferences();
      const written = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/home/centroid/relay_config/pki/ca.pem',
        tokenPath: '/etc/centroid/station.token',
      );
      await writeGatewayConfig(prefs, written);
      expect(await readGatewayConfig(prefs), written);
    });

    test('pinned material round-trips too, and beats the legacy path',
        () async {
      final prefs = InMemoryPreferences();
      const written = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caPem: _fakePem,
      );
      await writeGatewayConfig(prefs, written);
      final read = await readGatewayConfig(prefs);
      expect(read, written);
      expect(read.caPem, _fakePem);

      // Precedence, stated where the JSON is: a row that somehow carries
      // both dials on the material — the thing an operator approved a
      // fingerprint for — never on a path that may have rotted since.
      final both = written.copyWith(caCertPath: '/pki/old-ca.pem');
      final dial = await both.toClientConfig();
      expect(dial.tls!.rootCertPem, _fakePem);
      expect(dial.tls!.rootCertPath, isNull);
    });

    // A hand-edited or half-written row must not stop a panel booting, and
    // direct mode is the configuration the plant already runs.
    test('a corrupt row reads as direct mode rather than throwing', () async {
      final prefs = InMemoryPreferences();
      await prefs.setString(GatewayConfig.prefsKey, 'not json at all');
      expect(await readGatewayConfig(prefs), GatewayConfig.defaults);
    });

    // Parsing is by string, so renaming the enum constant cannot silently
    // re-point a plant full of gateway stations back to direct.
    test('an unknown mode string reads as direct', () async {
      final prefs = InMemoryPreferences();
      await prefs.setString(
          GatewayConfig.prefsKey, jsonEncode({'mode': 'carrier-pigeon'}));
      expect((await readGatewayConfig(prefs)).mode, TransportMode.direct);
    });

    test('blank paths are stored as absent, not as empty strings', () async {
      final prefs = InMemoryPreferences();
      await prefs.setString(
          GatewayConfig.prefsKey,
          jsonEncode({
            'mode': 'gateway',
            'url': 'ws://localhost:9443',
            'ca_cert_path': '   ',
            'token_path': '',
          }));
      final read = await readGatewayConfig(prefs);
      expect(read.caCertPath, isNull);
      expect(read.tokenPath, isNull);
    });
  });

  group('GatewayConfig.validationError', () {
    // The whole point of the refusal living here: the operator reads it with
    // the keyboard still in their hands, not as a dark screen at next boot.
    test('direct mode never refuses, whatever else is filled in', () {
      const config = GatewayConfig(mode: TransportMode.direct, url: 'nonsense');
      expect(config.validationError, isNull);
    });

    test('an empty address is refused with the shape to type', () {
      const config = GatewayConfig(mode: TransportMode.gateway);
      expect(config.validationError, contains('wss://'));
    });

    test('a non-URL is refused', () {
      const config =
          GatewayConfig(mode: TransportMode.gateway, url: 'just some words');
      expect(config.validationError, contains('Not a URL'));
    });

    test('http is refused: this is a WebSocket', () {
      const config = GatewayConfig(
          mode: TransportMode.gateway, url: 'https://10.50.10.11:9443');
      expect(config.validationError, contains('wss'));
    });

    // The one deliberate weakening in this getter's history. wss with no
    // trust used to be refused *here*, which disabled Save — but Save is now
    // the thing that acquires trust (fetch → fingerprint → approve), so the
    // edit-time getter must let it through. What must NOT weaken is the boot
    // side: a hand-edited trustless row still cannot dial, and `undialable`
    // is the getter `stateManProvider` consults for exactly that, so the
    // 15-08 honesty chain (build failure → notBuilt → "Panel misconfigured")
    // holds end to end.
    test('wss without trust: Save may proceed, the dial may not', () {
      const config = GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443');
      expect(config.validationError, isNull,
          reason: 'refusing here would disable the Save that performs the '
              'acquisition — the deadlock the pem-path field used to hide');
      expect(config.needsTrustAcquisition, isTrue);
      expect(config.undialable, contains('CA'),
          reason: 'the boot guard must still refuse: without a root every '
              'handshake fails with the message a genuine impostor produces');
    });

    test('wss with pinned material is dialable and needs no acquisition', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caPem: _fakePem,
      );
      expect(config.validationError, isNull);
      expect(config.undialable, isNull);
      expect(config.needsTrustAcquisition, isFalse);
    });

    test('a legacy path still satisfies the boot guard', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
      );
      expect(config.undialable, isNull);
      expect(config.needsTrustAcquisition, isFalse,
          reason: 'a station provisioned by mount is provisioned; fetching '
              'over it would re-ask a question that was answered');
    });

    test('pinned material on a plaintext dial is refused like a path is', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'ws://10.50.10.11:9443',
        caPem: _fakePem,
      );
      expect(config.validationError, contains('never consulted'),
          reason: 'the mistake is about the dial, not about how the root '
              'was provisioned — material must not slip past the refusal '
              'the path variant earns');
    });

    test('wss with a pinned root is accepted', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
      );
      expect(config.validationError, isNull);
      expect(config.uri.scheme, 'wss');
    });

    // The mirror refusal: a config that reads as encrypted while the traffic
    // is not is the kind of thing found by a packet capture months later.
    test('a pinned root on a plaintext dial is refused', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'ws://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
      );
      expect(config.validationError, contains('never consulted'));
    });

    test('a credential on a plaintext dial is refused', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'ws://10.50.10.11:9443',
        tokenPath: '/etc/station.token',
      );
      expect(config.validationError, contains('in the clear'));
    });

    test('a bare ws bench gateway is accepted', () {
      const config =
          GatewayConfig(mode: TransportMode.gateway, url: 'ws://localhost:9443');
      expect(config.validationError, isNull);
    });
  });

  group('the legacy path migrates on save, never on load', () {
    test('a readable legacy file becomes pinned material, path dropped',
        () async {
      final dir = Directory.systemTemp.createTempSync('gateway-config-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/ca.pem';
      File(path).writeAsStringSync(_fakePem);

      final legacy = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: path,
      );
      final migrated = legacy.migrateLegacyTrust();
      expect(migrated.caPem, _fakePem,
          reason: 'the material pinned is exactly what the station already '
              'trusted — same bytes, new home, no new trust decision');
      expect(migrated.caCertPath, isNull,
          reason: 'keeping the path too would leave two answers to "what '
              'does this panel trust", which stop agreeing the first time '
              'the file is edited');
    });

    test('an unreadable legacy file is kept as a path, not traded for null',
        () async {
      const legacy = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/no/such/file.pem',
      );
      expect(legacy.migrateLegacyTrust(), legacy,
          reason: 'never trade a working configuration shape for a broken '
              'one silently — a path that fails at boot at least fails with '
              'the notBuilt report naming the file');
    });

    test('a file with no certificate in it is not pinned', () async {
      final dir = Directory.systemTemp.createTempSync('gateway-config-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/ca.pem';
      File(path).writeAsStringSync('not pem at all');

      final legacy = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: path,
      );
      expect(legacy.migrateLegacyTrust(), legacy);
    });

    test('material already pinned is left exactly alone', () async {
      const pinned = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caPem: _fakePem,
      );
      expect(pinned.migrateLegacyTrust(), same(pinned));
    });
  });

  group('what the config renders as', () {
    test('toString never carries the certificate body', () {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caPem: _fakePem,
      );
      expect(config.toString(), isNot(contains('BEGIN CERTIFICATE')),
          reason: 'public material or not, a config that dumps a PEM into '
              'every log line trains people to stop reading configs');
    });

    test('material participates in equality, so the save button can tell',
        () {
      const a = GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://10.50.10.11:9443',
          caPem: _fakePem);
      const b = GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443');
      expect(a == b, isFalse,
          reason: 'the Save button is the page\'s only unsaved indicator, '
              'and it diffs these two objects — a pin that equality cannot '
              'see is a pin the operator cannot save');
    });
  });

  group('GatewayConfig.toClientConfig', () {
    test('pinned material dials as material', () async {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caPem: _fakePem,
      );
      final dial = await config.toClientConfig();
      expect(dial.tls, isNotNull);
      expect(dial.tls!.rootCertPem, _fakePem);
      expect(dial.tls!.rootCertPath, isNull);
    });

    test('no credential file means no token on the wire', () async {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
      );
      final client = await config.toClientConfig();
      expect(client.token, isNull);
      expect(client.tls?.rootCertPath, '/pki/ca.pem');
    });

    // Read off disk at connect time and never written back: the secret must
    // not end up in a preferences row, a database backup or a support bundle.
    test('the credential is read from the file, trimmed', () async {
      final dir = await Directory.systemTemp.createTemp('gateway_token');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/station.token');
      await file.writeAsString('  s3cret-station-token\n');

      final config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
        tokenPath: file.path,
      );
      expect((await config.toClientConfig()).token, 's3cret-station-token');
    });

    // A panel that quietly drops its credential connects as an unknown station
    // and is refused with a message about authentication, which sends the
    // engineer to the wrong end of the wire.
    test('a missing credential file throws rather than dialling anonymously',
        () async {
      const config = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
        caCertPath: '/pki/ca.pem',
        tokenPath: '/no/such/station.token',
      );
      expect(config.toClientConfig(), throwsA(isA<FileSystemException>()));
    });
  });

  // ---------------------------------------------------------------------------
  // The hostname advisory (rig FIND-B)
  //
  // The rig's probe leaf is CN=10.50.10.11, SAN: IP Address:10.50.10.11, with
  // no DNS name at all. An operator who types a hostname fails TLS with a
  // message about *trust*, which sends them to the CA file — the wrong end of
  // the wire, and an afternoon gone. The advisory says so while the keyboard is
  // still in their hands.
  //
  // It is a warning, not a refusal: a plant that provisions DNS SANs is
  // legitimate, and a config an operator cannot save is worse than one they can
  // save and correct.
  //
  // Every negative arm below is PAIRED with the positive control in the same
  // test. A getter that collapsed to `return null` would otherwise satisfy five
  // of these arms while doing nothing at all.
  // ---------------------------------------------------------------------------

  group('the hostname advisory', () {
    /// The rig's own address, verbatim. The one dial that must stay quiet.
    const rigAddress = GatewayConfig(
      mode: TransportMode.gateway,
      url: 'wss://10.50.10.11:9444',
      caCertPath: '/pki/ca.pem',
    );

    /// The same gateway written as a name. The positive control for every
    /// negative arm in this group.
    const byName = GatewayConfig(
      mode: TransportMode.gateway,
      url: 'wss://plc-gw.svn:9444',
      caCertPath: '/pki/ca.pem',
    );

    test('a wss host that is a name warns about the certificate SAN', () {
      final advisory = byName.advisory;
      expect(advisory, isNotNull);
      expect(advisory, contains('subject-alternative name'));
      // It names the host being typed, so the sentence is about *this* field
      // rather than about gateways in general.
      expect(advisory, contains('plc-gw.svn'));
      // The wrong-end failure it exists to prevent: TLS reports a name/SAN
      // mismatch as a trust problem, which sends the operator to the CA file.
      expect(advisory, contains('trust'));
    });

    // A hint that is always shown is a hint nobody reads, and the rig's own
    // address is precisely the dial that has to stay quiet.
    test("the rig's own IP-literal address gets no advisory", () {
      expect(rigAddress.advisory, isNull);
      expect(byName.advisory, isNotNull);
    });

    // Uri.host strips the brackets off an IPv6 literal, so the naive
    // `host.contains('.')` test somebody will "simplify" this to reads
    // `fd00::1` as a name. This arm is why InternetAddress.tryParse is the one
    // spelling in the phase.
    test('an IPv6 literal gets no advisory either', () {
      const v6 = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://[fd00::1]:9444',
        caCertPath: '/pki/ca.pem',
      );
      expect(Uri.parse(v6.url).host, 'fd00::1',
          reason: 'Uri.host strips the brackets; a dot test would misread this');
      expect(v6.advisory, isNull);
      expect(byName.advisory, isNotNull);
    });

    // The advisory is about certificate verification, and there is no
    // certificate on a plaintext dial. Same hostname, different scheme.
    test('a plaintext ws bench gateway gets no advisory', () {
      const bench =
          GatewayConfig(mode: TransportMode.gateway, url: 'ws://bench-gw:9444');
      expect(bench.validationError, isNull, reason: 'a bench dial is dialable');
      expect(bench.advisory, isNull);
      expect(byName.advisory, isNotNull);
    });

    test('direct mode never advises, whatever is in the address field', () {
      final direct = byName.copyWith(mode: TransportMode.direct);
      expect(direct.advisory, isNull);
      expect(byName.advisory, isNotNull);
    });

    // One refusal at a time. A text field showing two complaints about the same
    // half-typed string is noise, and the refusal is the one that must be read.
    test('a config that is already refused advises about nothing', () {
      const cases = <String, GatewayConfig>{
        'empty': GatewayConfig(mode: TransportMode.gateway),
        'unparseable': GatewayConfig(
          mode: TransportMode.gateway,
          url: 'just some words',
          caCertPath: '/pki/ca.pem',
        ),
      };
      for (final entry in cases.entries) {
        expect(entry.value.validationError, isNotNull,
            reason: '${entry.key} must still be refused');
        expect(entry.value.advisory, isNull,
            reason: '${entry.key} is refused, so it must not also advise');
      }
      // 'wss with no CA root' used to sit in the refused set above. It moved
      // sides with the one-URL flow: no longer an edit-time refusal (Save is
      // the acquisition step), so a *hostname* dial with no trust yet is now
      // exactly the moment the SAN advisory earns its keep — the operator is
      // about to approve a fingerprint for a certificate that must carry
      // that name.
      const unpinnedByName = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://plc-gw.svn:9444',
      );
      expect(unpinnedByName.validationError, isNull);
      expect(unpinnedByName.advisory, isNotNull);
      // The control: the same hostname, once it IS dialable, does advise.
      expect(byName.advisory, isNotNull);
    });

    // The pair that makes "must not disable Save" possible at all. The Save
    // button's enable condition is `_hasUnsavedChanges && refusal == null`
    // where `refusal` is validationError alone
    // (lib/pages/server_config.dart:1147-1179). The widget-level arm belongs to
    // plan 15-05; this is the value-level half of the same property.
    test('an advisory is not a refusal: Save stays enabled', () {
      expect(byName.validationError, isNull);
      expect(byName.advisory, isNotNull);

      // Modelled exactly as the button computes it, with unsaved edits pending.
      const hasUnsavedChanges = true;
      final saveEnabled = hasUnsavedChanges && byName.validationError == null;
      expect(saveEnabled, isTrue,
          reason: 'an operator who cannot save a legal hostname is worse off '
              'than one who saves it and corrects the certificate');
    });

    // -----------------------------------------------------------------------
    // The collapse, judged against a live control.
    //
    // 15-01 wrote its own `_isIpLiteral` and promised to fold it onto this
    // getter "when 15-02 lands". 15-02 landed at `81f8af6e` and the fold never
    // happened, so the comment in `gateway_config.dart` claiming the SAN hint
    // "calls this getter rather than growing a second spelling" was a false
    // statement in `lib/` for two plans. 15-08 performed the collapse — onto
    // the pure spelling, because the other caller may not import `dart:io`.
    //
    // That direction is a downgrade on degenerate input, so it is measured
    // rather than assumed: `InternetAddress.tryParse` stays here as the
    // control, every host below is run through both, and the ONE case where
    // they still differ is named. Anything else diverging fails by host.
    // -----------------------------------------------------------------------
    test('the one host-shape predicate agrees with the OS resolver', () {
      const hosts = [
        // Ordinary addresses.
        '10.50.10.11', '127.0.0.1', '0.0.0.0', '255.255.255.255',
        // Not addresses.
        '256.1.1.1', '1.2.3', '1.2.3.4.5', '999.1.1.1', '1.2.3.-4',
        // The four the spelling this replaced got wrong, and why: int.tryParse
        // accepts a leading `+`, and with no radix it accepts a `0x` prefix.
        '1.2.3.+4', '0x1.2.3.4', '1.2.3. 4', '1.2.3.4 ',
        // IPv6, as `Uri.host` hands it over — brackets already stripped.
        '::1', 'fe80::1', 'fd00::1', '2001:db8::8a2e:370:7334',
        // A name with a stray colon. An address to the old spelling, because
        // any colon at all counted as IPv6.
        'a:b',
        // Names.
        'plc-gw.svn', 'gateway', 'gw.example.com', 'xn--80ak6aa92e.com',
        '', '1e2.3.4.5', '1.2.3.4e0',
      ];

      /// The single measured residue. `Uri` cannot produce a dial from it, so
      /// neither surface this predicate feeds is reachable with it — but it is
      /// written down here rather than left for somebody to rediscover.
      const knownDivergence = {':::'};

      /// Leading-zero forms, which the OS resolver classifies **differently on
      /// different platforms** — so they cannot be compared against it.
      ///
      /// BSD/macOS `inet_aton` accepts them (historically octal); glibc's
      /// `inet_pton` refuses them precisely because `010` is ambiguous. This
      /// arm was written on macOS and asserted "leading zeros are addresses to
      /// the OS" as if universal; CI found it on ubuntu AND windows with
      /// `"01.02.03.04"`, where the OS says no and this predicate says yes.
      ///
      /// The cases stay pinned — dropping them would lose the coverage — but
      /// against OUR OWN stated classification rather than an oracle that
      /// moves under the test. Which way the predicate calls them barely
      /// matters (both surfaces it feeds degrade gracefully either way); that
      /// it answers the SAME way on every platform is the property.
      const leadingZeroForms = {'01.02.03.04', '1.2.3.04', '010.1.1.1'};

      for (final host in leadingZeroForms) {
        expect(isIpLiteralHost(host), isTrue,
            reason: '"$host" must classify identically on every platform. If '
                'this changes, the advisory and the SAN hint change with it '
                'and they must never disagree with each other');
      }

      for (final host in [...hosts, ...knownDivergence]) {
        final os = InternetAddress.tryParse(host) != null;
        final ours = isIpLiteralHost(host);
        if (knownDivergence.contains(host)) {
          expect(ours, isNot(os),
              reason: '"$host" is the stated exception. If it now AGREES, '
                  'delete it from knownDivergence rather than leaving a '
                  'comment claiming a divergence that is gone');
          continue;
        }
        expect(ours, os,
            reason: '"$host": the pure predicate and the OS resolver must not '
                'disagree about a host somebody could actually type. They '
                'feed the two halves of rig FIND-B — the advisory while the '
                'operator is typing and the SAN hint when the handshake fails '
                '— and a host that gets one without the other is worse than '
                'a host that gets neither');
      }
    });

    test('and the advisory is the caller, so the two halves cannot drift', () {
      // The property the collapse exists for, asserted end to end rather than
      // on the helper alone: a host the predicate calls an address gets no
      // advisory, and a host it calls a name gets one. An advisory that had
      // kept its own spelling would pass every arm above and still disagree
      // with the hint.
      for (final host in ['10.50.10.11', 'fd00::1', 'plc-gw.svn', 'gateway']) {
        final config = GatewayConfig(
          mode: TransportMode.gateway,
          url: host.contains(':') ? 'wss://[$host]:9444' : 'wss://$host:9444',
          caCertPath: '/pki/ca.pem',
        );
        expect(config.advisory == null, isIpLiteralHost(host),
            reason: '"$host": the advisory and the SAN hint must reach the '
                'same conclusion, because they are the proactive and reactive '
                'halves of one finding');
      }
    });

    // The blast-radius guard. Walks the inputs and pins the sentence each
    // returns today. **One arm moved on purpose** (one-field gateway config):
    // wss-without-trust left `validationError` for `undialable`, because Save
    // is now the acquisition step and an edit-time refusal would disable it.
    // This test is exactly where that move was made loud.
    test('the validationError arms return exactly what they returned', () {
      expect(const GatewayConfig(mode: TransportMode.gateway).validationError,
          'Enter the gateway address, e.g. wss://10.50.10.11:9443');
      expect(
          const GatewayConfig(
                  mode: TransportMode.gateway, url: 'just some words')
              .validationError,
          'Not a URL: expected wss://host:port');
      expect(
          const GatewayConfig(
                  mode: TransportMode.gateway, url: 'https://10.50.10.11:9443')
              .validationError,
          'Scheme must be wss (or ws for a bench gateway), not https');
      // The moved arm: null at edit time, and the sentence lives on the boot
      // guard — pinned here so neither half can drift without this reddening.
      expect(
          const GatewayConfig(
                  mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443')
              .validationError,
          isNull);
      expect(
          const GatewayConfig(
                  mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443')
              .undialable,
          'wss needs the plant CA pinned first: without it every handshake '
          'fails with the same error a real impostor produces. Save on the '
          'Server Config page fetches the gateway\'s identity for approval');
      expect(
          const GatewayConfig(
            mode: TransportMode.gateway,
            url: 'ws://10.50.10.11:9443',
            caCertPath: '/pki/ca.pem',
          ).validationError,
          'A CA root on a ws:// dial is never consulted — the config would '
          'read as encrypted while the traffic is not');
      expect(
          const GatewayConfig(
            mode: TransportMode.gateway,
            url: 'ws://10.50.10.11:9443',
            tokenPath: '/etc/station.token',
          ).validationError,
          'A station credential on a ws:// dial crosses the plant LAN in '
          'the clear on every reconnect');
    });

    // FIND-C: gateway mode still opens Postgres for sign-in, preferences and
    // the audit trail (lib/providers/database.dart has no transport branch).
    // Paired absence/presence — an absence alone passes on an empty file. The
    // shape is test/widgets/audit_trail_row_test.dart:334-355.
    //
    // The presence half is scoped to `gateway`'s OWN doc block rather than to
    // the whole file: `TransportMode.direct`'s doc has always said "Postgres
    // pool", so a file-wide `contains('Postgres')` is satisfied before this
    // plan changes anything, and would prove nothing.
    test('TransportMode.gateway says the panel opens no database connection',
        () {
      // RETARGETED, not weakened. This arm was written when the rig had
      // MEASURED a live Postgres connection in gateway mode (13-RIG-E2E
      // FIND-C), and it pinned the doc to admit it rather than claim the
      // panel opened "nothing else". That connection is now gone —
      // `databaseProvider` branches on the transport before it reads the
      // configuration row, spawns a pool or arms the retry probe — so the
      // claim the arm defended has become the false one. The pin survives
      // with its polarity flipped: the doc must still NAME Postgres (so a
      // reader learns what this mode does about the database at all) and must
      // now say the panel opens none of its own.
      final source = File('lib/core/gateway_config.dart').readAsStringSync();

      final lines = source.split('\n');
      final declaration = lines.indexWhere((l) => l.trim() == 'gateway;');
      expect(declaration, greaterThan(0),
          reason: 'the TransportMode.gateway declaration must be findable');
      final doc = <String>[];
      for (var i = declaration - 1; i >= 0; i--) {
        if (!lines[i].trim().startsWith('///')) break;
        doc.insert(0, lines[i]);
      }
      expect(doc, isNotEmpty, reason: 'gateway must carry a doc comment');
      // Normalised before matching: the doc is hand-wrapped prose, so a
      // phrase can straddle two `///` lines. A pin that only matches an
      // unwrapped sentence is a pin that goes red when somebody reflows a
      // paragraph, which teaches people to delete it.
      final text = doc
          .map((l) => l.trim().replaceFirst('///', ''))
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(text, contains('no direct database connection'),
          reason: 'the doc must state the panel opens none of its own — a doc '
              'that goes quiet about the database reads as an oversight');
      expect(text, contains('backend owns the database'),
          reason: 'and must say who does own it, or the reader is left to '
              'guess where preferences and sign-in come from');
    });
  });
}
