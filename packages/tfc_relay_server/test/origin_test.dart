@TestOn('vm')
@Tags(['ws'])

/// `allowedOrigins`: SEC-03's cross-site-WebSocket-hijacking clause, refused
/// before the 101.
///
/// A browser page on any origin can open a WebSocket to any host it likes —
/// there is no same-origin policy on the WebSocket handshake, only an `Origin`
/// header the server is expected to judge. Against this gateway that would be
/// a page rendering the plant's values and, with a token in hand, actuating
/// it. `shelf_web_socket` does the judging
/// (`web_socket_handler.dart:71-77`), the wiring already passes the list from
/// the config rather than a literal (`relay_server.dart`, threat T-03-10), and
/// 06-RESEARCH §F measured all nine configurations. So what Phase 6 owes SEC-03
/// is **evidence, not a change** — these arms, and the pin below.
///
/// **The pin is the point.** The check is skipped entirely when the configured
/// list is `null`: `origin != null && _allowedOrigins != null && !contains(…)`.
/// So `null` does not mean "no restriction configured yet", it means
/// "cross-site WebSocket hijacking is permitted", and in a diff it reads
/// almost exactly like the empty list that means the opposite. The type is the
/// only thing between those two, which makes the type a tested property.
///
/// Nullability is **not visible to `dart:mirrors`** — measured here: a
/// `List<String>?` field reports `reflectedType` of `List<String>` and
/// `reflectType(Null).isSubtypeOf(field.type)` of `false`, identically to the
/// non-nullable declaration. So the pin is three cheap mechanisms rather than
/// one reflected type: the declaration's own source text, the default value at
/// runtime, and the reflected type family.
///
/// Every arm runs over **plaintext** on purpose. The origin check happens at
/// the HTTP upgrade, above TLS; running these through wss would make a failure
/// ambiguous between a refused origin and a certificate the client would not
/// take.
///
/// Without this file, the one defence between a malicious page and the plant
/// is a default nobody has ever asserted.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/permissive_resolver.dart';

/// The ceiling on any dial or upgrade here (trap 17). A hang guard, not a
/// measurement.
const _dialBudget = Duration(seconds: 10);

/// A configured origin, and one that is not it.
const _listed = 'https://hmi.svn.local';
const _unlisted = 'https://evil.example';

void main() {
  /// A plaintext gateway on an ephemeral loopback port.
  ///
  /// A null [allowedOrigins] means "say nothing and let `ServerConfig` supply
  /// its own default" — **not** "configure an empty list". The distinction is
  /// the whole of the group below: a helper that passed `const []` on the
  /// caller's behalf would test the helper's default and leave the config's
  /// unexercised, and the mutation this file exists to catch changes exactly
  /// that default.
  Future<RelayServer> startServer({List<String>? allowedOrigins}) async {
    final served = FakeStateMan();
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: served,
      config: allowedOrigins == null
          ? ServerConfig(tick: ServerConfig.minTick)
          : ServerConfig(
              tick: ServerConfig.minTick, allowedOrigins: allowedOrigins),
      onError: (_, __, ___) {},
    );
    addTearDown(() async {
      await server.close();
      await served.dispose();
    });
    await server.start();
    return server;
  }

  /// The HTTP status the gateway answers a WebSocket upgrade with.
  ///
  /// A raw `HttpClient` rather than `IOWebSocketChannel`, so a refusal is
  /// observable as the **status code** the browser would see and not only as
  /// the exception a Dart client turns it into. Both views are pinned; they
  /// are the same event seen from two places, and 06-05 needs the second one.
  Future<int> upgradeStatus(int port, {String? origin}) async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client
        .openUrl('GET', Uri.parse('http://127.0.0.1:$port/'))
        .timeout(_dialBudget);
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key',
          base64.encode(List<int>.generate(16, (i) => i * 7 % 256)));
    if (origin != null) request.headers.set('Origin', origin);

    final response = await request.close().timeout(_dialBudget);
    if (response.statusCode == HttpStatus.switchingProtocols) {
      // Detached and destroyed rather than drained: a 101 has no body to
      // drain, and a socket left attached holds the server's session open
      // past the case that opened it.
      (await response.detachSocket()).destroy();
    } else {
      await response.drain<void>();
    }
    return response.statusCode;
  }

  group('under the default empty list', () {
    test('an upgrade with no Origin header is accepted', () async {
      final server = await startServer();

      expect(await upgradeStatus(server.port), HttpStatus.switchingProtocols,
          reason: 'a panel is not a browser and sends no Origin. If the empty '
              'default refused those too, the CSWSH defence would be a total '
              'outage and somebody would configure it away within the hour');
    });

    test('a browser origin is refused before the upgrade', () async {
      final server = await startServer();

      expect(await upgradeStatus(server.port, origin: _unlisted),
          HttpStatus.forbidden,
          reason: 'a page on any origin can open a WebSocket to any host — '
              'there is no same-origin policy on this handshake. Refusing '
              'before the 101 is what keeps a malicious page from reading the '
              'plant and, with a token, actuating it');
    });
  });

  group('with a configured list', () {
    test('the listed origin upgrades', () async {
      final server = await startServer(allowedOrigins: const [_listed]);

      expect(await upgradeStatus(server.port, origin: _listed),
          HttpStatus.switchingProtocols,
          reason: 'the web bundle ships from this origin; refusing it would '
              'make the allow-list a deny-all');
    });

    test('an unlisted origin is refused', () async {
      final server = await startServer(allowedOrigins: const [_listed]);

      expect(await upgradeStatus(server.port, origin: _unlisted),
          HttpStatus.forbidden);
    });

    test('a mixed-case Origin header matches a lowercase configured list',
        () async {
      final server = await startServer(allowedOrigins: const [_listed]);

      expect(await upgradeStatus(server.port, origin: 'HTTPS://HMI.SVN.LOCAL'),
          HttpStatus.switchingProtocols,
          reason: 'the header is lowercased at the check and the configured '
              'list at construction, so case is handled on both sides and no '
              'normalisation is owed here — a case-sensitive comparison would '
              'refuse a legitimate browser for the shape of its address bar');
    });

    test('a mixed-case configured entry matches a lowercase header', () async {
      final server =
          await startServer(allowedOrigins: const ['HTTPS://HMI.SVN.LOCAL']);

      expect(await upgradeStatus(server.port, origin: _listed),
          HttpStatus.switchingProtocols);
    });
  });

  group('what the client sees', () {
    test('a refusal is distinguishable from a certificate failure', () async {
      final server = await startServer();

      final ws = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        headers: const {'Origin': _unlisted},
        connectTimeout: _dialBudget,
      );
      addTearDown(() => ws.sink.close().catchError((Object _) {}));
      // The same error is queued on the stream; consumed here so it cannot
      // arrive in the ambient isolate and be attributed to another case.
      ws.stream.listen(null, onError: (Object _) {}, cancelOnError: true);

      Object? raised;
      try {
        await ws.ready;
      } catch (error) {
        raised = error;
      }

      expect(raised, isA<WebSocketChannelException>());
      final inner = (raised as WebSocketChannelException).inner;
      expect(inner, isA<WebSocketException>(),
          reason: 'an origin refusal is an HTTP answer the client understood, '
              'not a transport that failed');
      expect(inner, isNot(isA<HandshakeException>()),
          reason: '06-05 classifies failures by this distinction: a refused '
              'origin is a configuration mistake somebody can fix in a file, '
              'a HandshakeException is a trust problem needing the root '
              're-provisioned, and the two send an engineer to opposite ends '
              'of the plant');
      expect('$raised', contains('403'),
          reason: 'the status has to survive into the message, or the only '
              'thing an operator gets is "connection failed"');
      expect(ws.closeCode, isNull,
          reason: 'the refusal happens before the upgrade, so there is no '
              'WebSocket to close and never will be a code for this — '
              'anything reading one would report a clean disconnect');
    });
  });

  group('the check cannot be accidentally disabled', () {
    test('allowedOrigins is declared non-nullable in the source', () {
      final source = File('lib/src/server_config.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      expect(source, contains('final List<String> allowedOrigins;'),
          reason: 'SEC-03: shelf_web_socket skips the origin check entirely '
              'when the list is null, so List<String>? is not "unset", it is '
              '"cross-site WebSocket hijacking permitted". Nullability is '
              'invisible to dart:mirrors — measured, see this library\'s doc '
              '— so the declaration\'s own text is the pin.');
      expect(source, isNot(contains('List<String>? allowedOrigins')),
          reason: 'the same property from the other side, so a second '
              'declaration cannot slip in beside the first');
    });

    test('the default is an empty list, never null', () {
      // `Object?` deliberately, and the lint is suppressed rather than
      // obeyed: the analyzer is right that the field is non-nullable *today*,
      // and widening here is what keeps this case compiling — and therefore
      // failing by name — on the day somebody makes it nullable. A
      // non-nullable local would turn the mutation into a load error and this
      // file would stop reporting which property broke.
      // ignore: unnecessary_nullable_for_final_variable_declarations
      final Object? origins = ServerConfig().allowedOrigins;

      expect(origins, isNotNull,
          reason: 'an empty list refuses every browser Origin; a null accepts '
              'every one of them, and the two read almost identically in a '
              'config diff');
      expect(origins, isEmpty,
          reason: 'the default is deny-all-browsers, not allow-one — the real '
              'list arrives when the web bundle does');
    });

    test('the reflected type is still a list of strings', () {
      final field = reflectClass(ServerConfig)
          .declarations
          .values
          .whereType<VariableMirror>()
          .firstWhere((d) =>
              MirrorSystem.getName(d.simpleName) == 'allowedOrigins');

      expect(field.type.reflectedType, List<String>,
          reason: 'this catches the type family changing under the source pin '
              '— a Set, or a List<Object> — which the text check above would '
              'notice too but only by accident of spelling');
    });
  });
}
