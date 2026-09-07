import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc_dart/core/preferences.dart';

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

    // Mirrors ClientConfig.checkDialable. Without the root every handshake
    // fails with the message a genuine impostor produces, so the panel reports
    // an attack rather than a missing file.
    test('wss without a pinned root is refused', () {
      const config = GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443');
      expect(config.validationError, contains('CA root'));
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

  group('GatewayConfig.toClientConfig', () {
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
        'wss with no CA root': GatewayConfig(
          mode: TransportMode.gateway,
          url: 'wss://plc-gw.svn:9444',
        ),
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

    // The blast-radius guard. `advisory` is new; validationError is not, and a
    // later edit to that getter must not be silently absorbed by this plan's
    // diff. Walks all six inputs and pins the sentence each returns today.
    test('the six validationError arms return exactly what they returned', () {
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
      expect(
          const GatewayConfig(
                  mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443')
              .validationError,
          'wss needs the plant CA root: without it every handshake fails '
          'with the same error a real impostor produces');
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
    test('TransportMode.gateway no longer claims the panel opens nothing else',
        () {
      final source = File('lib/core/gateway_config.dart').readAsStringSync();
      expect(source, isNot(contains('nothing else')),
          reason: 'the rig measured a live Postgres connection in gateway mode');

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
      expect(doc.join('\n'), contains('Postgres'),
          reason: "gateway's own doc must name the connection it still opens, "
              "not lean on direct's");
    });
  });
}
