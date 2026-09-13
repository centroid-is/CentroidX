/// The whole contract suite, and the four access families with it, judged over
/// a real **`wss://`** socket. ACCESS-02's second leg (17-14).
///
/// ## Why `wss://`, and why that is the point rather than a detail
///
/// The contract has run in memory (17-05) and over a plaintext channel; the
/// server package's own `ws_contract_test.dart` runs it over a real **`ws://`**
/// socket. This file is the same suite over TLS, with `supportsAccessControl:
/// true` so the twenty-seven access checks run rather than sitting in a named
/// gap.
///
/// 16-CONTEXT records the class of defect a plaintext-only leg misses: for the
/// whole life of `drain_close_test` the drain path was measured only over
/// `ws://`, and a fix that never worked over TLS passed CI the entire time —
/// because TLS framing coalesces and splits records differently from a raw
/// socket. This suite exercises **refusals**, and a refusal that behaves
/// differently under TLS framing — an `AccessDenied` that arrives truncated, a
/// deny that races the close — is exactly the kind of thing nobody finds until
/// a plant. So the access families cross a real TLS record layer here.
///
/// ## What this leg is, and is not
///
/// It is the transport-contract leg: `ServedStateMan` and `ChannelStateMan` on
/// either end of a real TLS WebSocket, with a `FakeStateMan`/`FakeAccessServices`
/// reference implementation behind the served end. The reference gates by the
/// session the contract's `actAs` lever installs (off the wire, as the kit
/// requires — a client that could name its own session could name one it does
/// not hold); the wire carries the calls and the refusals. This is the same
/// harness shape `ws_contract_test.dart` follows, TLS added and access opted in,
/// per the plan's instruction not to build a second harness.
///
/// It is **not** the relay's own policy gate over the wire — that is
/// `PolicyStateMan`, judged by `policy_test.dart`, the shipping-graph E2E in
/// `tfc_dart` (`gateway_access_e2e_test.dart`), and the whole-package suite
/// here. Nor does it use `RemoteStateMan`: that type lives in
/// `tfc_relay_client`, which depends on this package, so the edge cannot be
/// imported the other way. The relay-decode/client-encode agreement (17-08's
/// F-3) is proven end to end in the `tfc_dart` E2E, which drives the real
/// `RelayServer` over a socket with the client's own frame encoding.
///
/// ## The three sessions
///
/// The access checks are exercised under the kit's own sessions, swapped by
/// `actAs`: `configureSession` (`{configure}` — the refused neighbour),
/// `usersSession` (`{users, operate}` — templates and roles), and
/// `administerSession` (`{administer}` — the backend config), with
/// `everyGroupSession` as the anti-vacuity control and an empty session for the
/// ungated audit reads. Three real, distinct authorities at the far end, which
/// is what makes a permission arm mean something rather than a fixture's
/// say-so.
@TestOn('vm')
@Tags(['contract', 'ws'])
library;

import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/certs.dart';

/// The designated read-only key, character-identical to every other contract
/// leg (`ws_contract_test.dart:64`). Supplied so the read-only write case runs;
/// a leg judging a different set would make the parity claim meaningless.
const _readOnlyKey = 'ST301.CN21.SEN01.temp';

/// How long the served end has to appear after the client's connect returns.
/// A wiring budget, not a measurement — `ws_harness.dart:61`'s `_acceptBudget`.
const _acceptBudget = Duration(seconds: 10);

// ---------------------------------------------------------------------------
// TLS material, minted once for the isolate.
// ---------------------------------------------------------------------------

/// The one CA and its one leaf, minted lazily and reused for every case's TLS
/// context. The keypairs behind them are cached by `certKeyPairs()`, so this is
/// a handful of cheap signs rather than an RSA keygen per case; the PEM bytes go
/// straight into a `SecurityContext`, so no case touches the filesystem.
TestCa get _ca => _caCache ??= mintCa(commonName: 'Relay wss Contract CA');
TestCa? _caCache;

String get _leafChainPem => _leafCache ??= mintLeaf(ca: _ca);
String? _leafCache;

/// The server's TLS context: the leaf chain and its key, from bytes.
SecurityContext _serverSecurity() => SecurityContext(withTrustedRoots: false)
  ..useCertificateChainBytes(_leafChainPem.codeUnits)
  ..usePrivateKeyBytes(leafKeyPem().codeUnits);

/// A pinned client: the CA root and nothing else, so `wss://` is real pinning
/// and the machine's own trust store is never consulted (SEC-02).
HttpClient _pinnedClient() {
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(_ca.certPem.codeUnits);
  return HttpClient(context: context);
}

// ---------------------------------------------------------------------------
// The wss contract leg.
// ---------------------------------------------------------------------------

/// A `FakeStateMan` served over a real `wss://` socket, both ends wired.
///
/// The shape and defaults of `ws_harness.dart`'s `serveFakeOverWs`, with the
/// plaintext listener replaced by a TLS one and the client dial pinned to the
/// test CA. `make()` returns synchronously — the runner's constraint — so the
/// bind and the connect run inside a future the `ChannelStateMan`'s channel is
/// completed from.
final class _WssFakeWiring {
  _WssFakeWiring(this.served);

  final FakeStateMan served;

  HttpServer? _http;
  WebSocketChannel? _client;
  HttpClient? _clientHttp;
  final _sessions = <ServedStateMan>[];
  var _torn = false;

  Future<void> connect(StreamChannelCompleter<String> completer) async {
    try {
      final accepted = Completer<void>();
      _http = await shelf_io.serve(
        webSocketHandler((WebSocketChannel ws, String? _) {
          _sessions.add(serveStateMan(served, wsChannel(ws)));
          if (!accepted.isCompleted) accepted.complete();
        }),
        InternetAddress.loopbackIPv4,
        0,
        securityContext: _serverSecurity(),
      );

      final http = _clientHttp = _pinnedClient();
      final ws = IOWebSocketChannel.connect(
        Uri.parse('wss://127.0.0.1:${_http!.port}'),
        customClient: http,
        connectTimeout: _acceptBudget,
      );
      _client = ws;
      await ws.ready;
      await accepted.future.timeout(_acceptBudget);
      completer.setChannel(wsChannel(ws));
    } catch (error, stack) {
      completer.setError(error, stack);
    }
  }

  Future<void> teardown(Future<void> ready) async {
    if (_torn) return;
    _torn = true;
    await ready.catchError((Object _) {});
    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();
    await _http?.close(force: true);
    await _client?.sink.close().catchError((Object _) {});
    _clientHttp?.close(force: true);
    await served.dispose();
  }
}

/// One `wss://`-served `StateManApi`, per case — the runner's `make`.
///
/// The defaults are `ws_harness.dart`'s `wsServedFake` verbatim (`staleAfter`
/// 300 ms, no read-only keys marked here — the runner is told the read-only key
/// separately), so a defaults drift between legs reads as a transport
/// difference rather than hiding as one.
StateManApi wssServedFake() {
  final served = FakeStateMan(
    staleAfter: const Duration(milliseconds: 300),
  );
  final completer = StreamChannelCompleter<String>();
  final wiring = _WssFakeWiring(served);
  final ready = wiring.connect(completer);
  // Handled here so a leg nobody awaited cannot surface as an unhandled async
  // error in an unrelated case, and still delivered to the channel's peer.
  unawaited(ready.catchError((Object _) {}));

  final api = ChannelStateMan(
    channel: completer.channel,
    observables: served,
    closeServed: () => wiring.teardown(ready),
  );
  addTearDown(() => wiring.teardown(ready));
  return api;
}

// ---------------------------------------------------------------------------
// The AccessMethods coverage map: every wire name reached by at least one check.
// ---------------------------------------------------------------------------

/// Which `AccessMethods` name each contract access check exercises.
///
/// The set-level parity sweep in 13-11's shape, for the access surface: a leg
/// that runs the suite but skips half the wire is a different failure from a
/// leg that fails, and only a coverage assertion catches it. Every one of the
/// thirty names in `AccessMethods.all` must appear here, reached by a
/// named check; the arm below asserts the union covers the declared set with no
/// method left unexercised.
const _methodsByCheck = <String, Set<String>>{
  'creating a template refuses a configure session and permits a users one': {
    AccessMethods.templateCreate,
  },
  'updating a template refuses configure and permits users': {
    AccessMethods.templateCreate,
    AccessMethods.templateUpdate,
  },
  'renaming a template refuses configure and permits users': {
    AccessMethods.templateCreate,
    AccessMethods.templateRename,
  },
  'deleting a template refuses configure and permits users': {
    AccessMethods.templateCreate,
    AccessMethods.templateDelete,
  },
  'binding a key refuses configure and permits users': {
    AccessMethods.templateBind,
  },
  'unbinding a key refuses configure and permits users': {
    AccessMethods.templateBind,
    AccessMethods.templateUnbind,
  },
  'the template reads are ungated and still answer': {
    AccessMethods.templateCreate,
    AccessMethods.templateBind,
    AccessMethods.templateList,
    AccessMethods.templateBindings,
    AccessMethods.templateKeysBoundTo,
  },
  'a bound template delete is a domain refusal, not a permission one': {
    AccessMethods.templateCreate,
    AccessMethods.templateBind,
    AccessMethods.templateDelete,
  },
  'creating a role refuses configure and permits users': {
    AccessMethods.adminCreateRole,
  },
  'updating a role refuses configure and permits users': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminUpdateRole,
  },
  'deleting a role refuses configure and permits users': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminDeleteRole,
  },
  'renaming a role refuses configure and permits users': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminRenameRole,
  },
  'creating a user refuses configure and permits users': {
    AccessMethods.adminCreateUser,
  },
  'deleting a user refuses configure and permits users': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminDeleteUser,
  },
  'moving a user onto a role refuses configure and permits users': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminSetUserRole,
  },
  'flipping a station-account flag refuses configure and permits users': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminSetUserStationAccount,
  },
  'setting a role page whitelist refuses configure and permits users': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminSetRolePages,
  },
  'setting an account page whitelist refuses configure and permits users': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminSetUserPages,
  },
  'resetting a password refuses configure and permits users': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminSetUserPassword,
  },
  'the admin reads are ungated and still answer': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminCreateUser,
    AccessMethods.adminRoles,
    AccessMethods.adminListUsers,
  },
  'deleting the last users-holding role is refused as a domain rule': {
    AccessMethods.adminCreateRole,
    AccessMethods.adminDeleteRole,
  },
  'setUserPassword never echoes the secret and still succeeds': {
    AccessMethods.adminCreateUser,
    AccessMethods.adminSetUserPassword,
  },
  'the audit reads are ungated': {
    AccessMethods.auditEntries,
    AccessMethods.auditMemberCountsByAction,
    AccessMethods.auditDistinctWho,
  },
  'the audit trail records every decision, allowed and refused': {
    AccessMethods.templateCreate,
    AccessMethods.auditEntries,
  },
  'reading the backend config refuses configure and permits administer': {
    AccessMethods.configRead,
  },
  'writing the backend config refuses configure and permits administer': {
    AccessMethods.configRead,
    AccessMethods.configWrite,
  },
  'the backend config is validated before it is persisted': {
    AccessMethods.configRead,
    AccessMethods.configWrite,
  },
  'a relay-section edit is refused by name': {
    AccessMethods.configRead,
    AccessMethods.configWrite,
  },
  "previous and restorePrevious follow write's gating": {
    AccessMethods.configRead,
    AccessMethods.configWrite,
    AccessMethods.configPrevious,
    AccessMethods.configRestorePrevious,
  },
};

void main() {
  var ran = 0;

  final before = contractCasesRegistered;
  group('the whole contract, over a real wss:// socket', () {
    setUp(() => ran++);
    runStateManContract(
      wssServedFake,
      readOnlyKey: _readOnlyKey,
      browseFixture: defaultBrowseFixture,
      supportsAccessControl: true,
    );
  });
  final registered = contractCasesRegistered - before;

  group('the run itself', () {
    test('every check ran over wss:// and the gap list is empty', () {
      final entitled = contractCases(
        readOnlyKey: _readOnlyKey,
        supportsAccessControl: true,
      );
      final gap =
          allContractChecks.keys.toSet().difference(entitled.keys.toSet());
      expect(gap, isEmpty,
          reason: 'this leg opted the access family in, so nothing is left in '
              'the named gap. A non-empty gap here is a check the wss:// leg '
              'does not reach — either the harness stopped serving a family or '
              'a check regressed; both are fixable and neither is worth '
              'lowering the flag for');
      expect(registered, allContractChecks.length,
          reason: 'the umbrella registered $registered of '
              '${allContractChecks.length} declared checks over wss://; with '
              'the access family opted in and the gap empty they must be equal, '
              'or a check exists that is neither run nor accounted for');
    });

    test('every registered check actually started over wss://', () {
      expect(ran, allContractChecks.length,
          reason: '$ran of $registered registered cases actually ran over the '
              'TLS socket. A shortfall is a case registered and then skipped, '
              'which the registration count cannot see — the report shows a '
              'skip reason, the suite stays green, and the property is as '
              'unjudged under TLS as it would be with the capability off');
    });

    test('the access check count is the same on all three legs — 29', () {
      // In memory (17-05, access_contract_meta_test), over the channel (17-08),
      // and over wss:// here: one declared set, so the count cannot drift
      // between legs without the meta test and this arm disagreeing.
      // 27 until the page-visibility whitelist merged in; setRolePages and
      // setUserPages take a check each, and both grade `users`.
      const declaredOnEveryLeg = 29;
      expect(accessChecks.length, declaredOnEveryLeg,
          reason: 'the kit declares ${accessChecks.length} access checks; the '
              'in-memory and channel legs run that many and so must this one. '
              'A leg that judged fewer would report parity while proving less');
      final accessRan = _methodsByCheck.keys.toSet();
      expect(accessRan, accessChecks.keys.toSet(),
          reason: 'the coverage map must name exactly the declared access '
              'checks — no more, no fewer — or the parity sweep below is '
              'measuring a stale set');
    });

    test('every AccessMethods.all name bar the named gap was exercised by at '
        'least one check over wss:// — the set-level parity sweep', () {
      // The one wire name the shared contract kit never drives: no access check
      // calls `backendConfig.validate` — the config checks read, write,
      // previous and restore, and validation is exercised only indirectly by
      // `write`'s validate-before-persist arm. So the method has a handler and
      // a client proxy but no contract coverage on ANY leg, in memory or over a
      // socket. It is named here rather than papered over, the same named-gap
      // discipline the roster carries elsewhere; 17-14 records it as a standing
      // contract-kit gap for a later plan to close with a `validate` check.
      const namedGap = {AccessMethods.configValidate};

      final exercised = <String>{
        for (final methods in _methodsByCheck.values) ...methods,
      };
      final unexercised =
          AccessMethods.all.difference(exercised).difference(namedGap);
      expect(unexercised, isEmpty,
          reason: 'these wire names are declared in AccessMethods.all, are not '
              'the named contract-kit gap, and yet no access check exercises '
              'them — so the suite could run green while they went unjudged '
              'over TLS forever: $unexercised. That is the '
              'leg-runs-half-the-surface failure this sweep exists to catch, '
              'distinct from a leg that fails');
      final stray = exercised.difference(AccessMethods.all);
      expect(stray, isEmpty,
          reason: 'the coverage map names $stray, which are not in '
              'AccessMethods.all — a stale entry that would let the sweep '
              'claim coverage of a method that no longer exists');
      // The gap is exactly one, and it is the one we named — so a second method
      // silently falling out of coverage cannot hide inside the exception.
      expect(AccessMethods.all.difference(exercised), namedGap,
          reason: 'the uncovered set must be exactly the named gap '
              '($namedGap); anything else is a NEW uncovered method wearing the '
              "known one's exemption");
      expect(AccessMethods.all, hasLength(30),
          reason: 'the access wire surface is thirty names — twenty-eight '
              'after the audit cut accessTemplates.template, plus the '
              'whitelist\'s setRolePages and setUserPages; a change to that '
              'count is a change to what this leg must cover, and it should '
              'be a deliberate edit');
    });
  });
}
