/// The measurement that matters (17-14, ACCESS-01): a gateway-mode panel with
/// **no database of its own** does the access-control work through a real
/// `wss://` socket, against a real backend with a real Postgres at the far end,
/// and the rows land in that Postgres — read back with SQL.
///
/// 17-12 proved the app takes the relayed route with `databaseProvider` null and
/// throwing, against a scripted gateway. This proves it against the shipping
/// graph: `composeBackendRelay` — the function `bin/main.dart` calls — bound on
/// a TLS socket, a raw panel with nothing but a socket in front of it, and the
/// backend's own TimescaleDB behind. *"Unused" is not "unavailable": a route
/// that exists will be taken*, so the panel here has no local route at all.
///
/// ## What the raw panel is, and why it is raw
///
/// `tfc_dart` depends on `tfc_relay_server` but not on `tfc_relay_client`, so
/// `RemoteStateMan` cannot be imported here (the edge is client → server). The
/// panel is a hand-built JSON-RPC socket — the shape `revocation_poll_test.dart`
/// established — which is the right instrument for a second reason: it lets each
/// frame be encoded with **the client's own wire convention**
/// (`client_sub_apis.dart`: `{value}`, `{role}`, `{query}` envelopes), so a
/// green arm here proves the relay's `access_handlers` **decode** agrees with
/// the client's **encode** end to end over the real wire. That is 17-08's F-3,
/// which no in-process leg could measure — and 17-14 fixed it server-side after
/// this arm first sent the envelope and the flat-map decoder rejected it.
///
/// ## The six requirement arms, plus revocation
///
/// One arm per ACCESS requirement, each naming the measurement, plus the
/// end-to-end revocation the whole phase turns on. Every number — row counts,
/// the close code, the poll — is quoted in 17-14-SUMMARY.md.
///
/// **The backendConfig leg (ACCESS-04/06).** 17-11 deviation 3 recorded a
/// standing gap — `composeBackendRelay` served `backendConfig` sessionlessly,
/// refusing -32011 on the wire — and the Phase 17 gate carried it forward by
/// name. That gap is now closed: the composition mints a per-identity
/// `BackendConfigStore` over the boot file (`statemanFilePath`), and the arm-4
/// group here measures BOTH polarities over the real socket: an
/// administer-holding station reads/validates/writes (edit lands in the file,
/// secrets redacted on the wire, relay section refused by name — D-10), an
/// unauthorised one is refused server-side with deny rows.
@Tags(['db'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessRole, AccessTemplate, kWholeKeyMember;
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_config_store.dart'
    show kSecretPreservedSentinel;
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
// A src import: `mint.dart` is not on the server's public barrel, but it is the
// only cert minter that encodes an IP SAN correctly (basic_utils encodes every
// SAN as dNSName, so a 127.0.0.1 dial gets CERTIFICATE_VERIFY_FAILED). The
// server's own test support imports it the same way.
// ignore: implementation_imports
import 'package:tfc_relay_server/src/tls/mint.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'docker_compose.dart';
import '../support/memory_secrets.dart';

/// `ServerErrorCodes.forbidden` (`tfc_relay_server/lib/src/error_codes.dart:88`)
/// — the wire code a policy refusal carries. Spelled as the literal the client's
/// `withAccessErrors` also matches (`client_sub_apis.dart:548`), because
/// `ServerErrorCodes` is not on the protocol barrel this file imports.
const int _kForbidden = -32005;

// ---------------------------------------------------------------------------
// TLS material, minted once for the run.
// ---------------------------------------------------------------------------

final _caKeys = generateKeyPair();
final _leafKeys = generateKeyPair();
final _caDn = {'CN': 'E2E Access CA', 'O': 'Centroid'};

String _caCertPem() {
  final now = DateTime.now().toUtc();
  return mintCertificate(
    signingKey: _caKeys.privateKey,
    issuer: _caDn,
    subject: _caDn,
    subjectPublicKey: _caKeys.publicKey,
    notBefore: now.subtract(const Duration(days: 1)),
    notAfter: now.add(const Duration(days: 3650)),
    ca: true,
  );
}

String _leafCertPem() {
  final now = DateTime.now().toUtc();
  return mintCertificate(
    signingKey: _caKeys.privateKey,
    issuer: _caDn,
    subject: {'CN': 'e2e-gateway', 'O': 'Centroid'},
    subjectPublicKey: _leafKeys.publicKey,
    sans: const ['localhost', '127.0.0.1'],
    notBefore: now.subtract(const Duration(days: 1)),
    notAfter: now.add(const Duration(days: 365)),
  );
}

// ---------------------------------------------------------------------------
// The raw panel: hello, a heartbeat, requests encoded the client's way, and the
// observed close code.
// ---------------------------------------------------------------------------

final class _Panel {
  _Panel._(this._ws, this._http);

  final WebSocketChannel _ws;
  final HttpClient? _http;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Completer<int?> _closed = Completer<int?>();
  int _nextId = 1;
  Timer? _heartbeat;
  var _torn = false;

  static Future<_Panel> connect(int port, String caCertPem) async {
    final http = HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(caCertPem.codeUnits),
    );
    final ws = IOWebSocketChannel.connect(
      Uri.parse('wss://127.0.0.1:$port'),
      customClient: http,
      connectTimeout: const Duration(seconds: 10),
    );
    final panel = _Panel._(ws, http);
    ws.stream.listen(
      panel._onFrame,
      onDone: () {
        if (!panel._closed.isCompleted) panel._closed.complete(ws.closeCode);
        panel._failAll(StateError('socket closed'));
      },
      onError: panel._failAll,
      cancelOnError: false,
    );
    await ws.ready;
    return panel;
  }

  Future<int?> get closeCode => _closed.future;
  bool get isClosed => _closed.isCompleted;

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) return; // a server notification
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (decoded['error'] != null) {
      completer.completeError(_RpcError(decoded['error'] as Map));
    } else {
      completer.complete(decoded['result']);
    }
  }

  void _failAll(Object error, [StackTrace? stack]) {
    final waiting = List.of(_pending.values);
    _pending.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(error, stack);
    }
  }

  Future<Object?> request(String method,
      {Object? params, Duration budget = const Duration(seconds: 8)}) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _ws.sink.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(budget, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('$method did not answer within $budget', budget);
    });
  }

  /// Sends [method] expecting a refusal, and hands back the RPC error.
  Future<_RpcError> refusal(String method, {Object? params}) async {
    try {
      await request(method, params: params);
    } on _RpcError catch (e) {
      return e;
    }
    fail('$method was answered instead of refused');
  }

  Future<relay.HelloResult> hello(String token) async {
    final raw = await request(
      relay.Methods.hello,
      params: relay.HelloParams(
        protocol: relay.protocolVersion,
        supported: const [relay.protocolVersion],
        client: const relay.PeerInfo('e2e-access-test', '0.1.0'),
        token: token,
      ).toJson(),
    );
    final result =
        relay.HelloResult.fromJson((raw as Map).cast<String, Object?>());
    final deadlineMs = result.heartbeatDeadlineMs;
    if (deadlineMs != null) {
      _heartbeat = Timer.periodic(Duration(milliseconds: deadlineMs ~/ 3), (_) {
        if (_torn || isClosed) return;
        unawaited(request(relay.Methods.ping).catchError((Object _) => null));
      });
    }
    return result;
  }

  Future<bool> stillAlive() async {
    if (isClosed) return false;
    try {
      await request(relay.Methods.ping, budget: const Duration(seconds: 3));
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> close() async {
    if (_torn) return;
    _torn = true;
    _heartbeat?.cancel();
    _failAll(StateError('panel torn down'));
    await _ws.sink.close().catchError((Object _) {});
    _http?.close(force: true);
  }
}

/// A JSON-RPC error the server sent, carrying the code the panel asserts on.
final class _RpcError implements Exception {
  _RpcError(Map raw)
      : code = raw['code'] as int?,
        message = '${raw['message']}';
  final int? code;
  final String message;
  @override
  String toString() => '_RpcError($code, $message)';
}

// ---------------------------------------------------------------------------

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      'ST101.CN01.MOT01.speed': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'ST101.CN01')
          ..serverAlias = 'ST101',
      ),
    });

/// Per-run marker so parallel suites and reruns do not collide in the shared
/// Postgres (`backend_access_db_test.dart`'s hygiene).
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

void main() {
  useMemorySecrets();

  late Database database;
  late Preferences prefs;
  late Directory tmp;
  late AccessRepository repo;

  // The station accounts, one per authority the arms need. Each token file
  // names ONE station per token: D-06 refuses two tokens sharing a station
  // (pulling one would revoke nothing and the sweep could not tell which live
  // session lost access), so every account gets a distinct station under a
  // shared per-run prefix the audit SQL and cleanup filter on.
  final adminUser = 'e2e-admin-$suffix'; // users + operate + administer
  final operUser = 'e2e-oper-$suffix'; // operate only
  final cfgUser = 'e2e-cfg-$suffix'; // operate + configure
  final adminStation = 'E2Ea$suffix';
  final operStation = 'E2Eo$suffix';
  final cfgStation = 'E2Ec$suffix';
  final stationLike = "station LIKE 'E2E%$suffix'";

  const adminTok = 'e2e-admin-token-0000000000000';
  const operTok = 'e2e-oper-token-00000000000000';
  const cfgTok = 'e2e-cfg-token-000000000000000';

  final adminRole = 'E2E Admin $suffix';
  final operRole = 'E2E Operate $suffix';
  final cfgRole = 'E2E Configure $suffix';

  late String tokenPath;
  late String caCertPem;

  setUpAll(() async {
    await startDockerCompose();
    await waitForDatabaseReady();
    database = await connectToDatabase();
    prefs = await Preferences.create(db: database);
    repo = AccessRepository(database.db);

    // Seed three roles and three station accounts in the real Postgres.
    await repo.upsertRole(AccessRole(
        name: adminRole,
        groups: const {
          AccessGroup.operate,
          AccessGroup.users,
          AccessGroup.administer
        }));
    await repo.upsertRole(
        AccessRole(name: operRole, groups: const {AccessGroup.operate}));
    await repo.upsertRole(AccessRole(
        name: cfgRole,
        groups: const {AccessGroup.operate, AccessGroup.configure}));
    for (final (u, r) in [
      (adminUser, adminRole),
      (operUser, operRole),
      (cfgUser, cfgRole),
    ]) {
      await repo.createUser(
          username: u, password: 'a-long-enough-password-1', roleName: r);
      await repo.setStationAccount(u, true);
    }

    // The token file: three tokens, one per account, each naming a user only.
    tmp = Directory.systemTemp.createTempSync('e2e-access-$suffix');
    tokenPath = '${tmp.path}/tokens.json';
    File(tokenPath).writeAsStringSync(jsonEncode({
      'tokens': {
        adminTok: {'username': adminUser, 'station': adminStation},
        operTok: {'username': operUser, 'station': operStation},
        cfgTok: {'username': cfgUser, 'station': cfgStation},
      },
    }));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', tokenPath]);

    // The TLS material on disk for composeBackendRelay to mount.
    caCertPem = _caCertPem();
    File('${tmp.path}/chain.pem').writeAsStringSync(_leafCertPem());
    File('${tmp.path}/key.pem')
        .writeAsStringSync(privateKeyToPem(_leafKeys.privateKey));
  });

  tearDownAll(() async {
    // Delete this run's rows only, users before roles (the FK points that way).
    await database.db.customStatement("DELETE FROM audit_entry WHERE $stationLike");
    await database.db.customStatement(
        "DELETE FROM app_user WHERE username LIKE 'e2e-%-$suffix'");
    await database.db
        .customStatement("DELETE FROM app_role WHERE name LIKE 'E2E %$suffix'");
    await database.db.customStatement(
        "DELETE FROM access_template WHERE name LIKE 'e2e-%-$suffix'");
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The shipping graph over the real DB and the real TLS token file, bound.
  ///
  /// [statemanPath] is the backend's own boot file (CENTROID_STATEMAN_FILE_PATH)
  /// for the config family to serve — the argument `bin/main.dart` passes.
  BackendRelayComposition composeAt(int port, {String? statemanPath}) {
    final config = RelayConfig.fromJson(<String, dynamic>{
      'relay': <String, dynamic>{
        'port': port,
        'credentials': <String, dynamic>{
          'source': 'token_file',
          'token_file': tokenPath,
        },
        'tls': <String, dynamic>{
          'chain_path': '${tmp.path}/chain.pem',
          'key_path': '${tmp.path}/key.pem',
        },
      },
    }, source: 'stateman.json')!;
    return composeBackendRelay(
      config: config,
      pipe: PipeMainEndpoint(),
      keyMappings: _mappings(),
      database: database,
      prefs: prefs,
      // The backend's own boot file, exactly as bin/main.dart passes it —
      // the slot whose absence was the gate's measured -32011.
      statemanFilePath: statemanPath,
      log: Logger(level: Level.off),
    );
  }

  /// Stands up the graph, refreshes the account cache (the embedder's order),
  /// binds, and connects a pinned panel that has said hello with [token].
  Future<(BackendRelayComposition, _Panel)> up(String token,
      {String? statemanPath}) async {
    final composed = composeAt(0, statemanPath: statemanPath);
    await composed.refreshAccounts();
    await composed.server.start();
    final panel = await _Panel.connect(composed.server.port, caCertPem);
    await panel.hello(token);
    return (composed, panel);
  }

  Future<int> count(String sql) async =>
      (await database.db.customSelect(sql).getSingle()).read<int>('c');

  // Client-envelope encoders (client_sub_apis.dart), so a green arm proves the
  // relay's access_handlers decode agrees with the client encode (F-3).
  Map<String, Object?> roleEnvelope(AccessRole r) =>
      {'role': relay.accessRoleToJson(r), 'reason': null};
  Map<String, Object?> templateEnvelope(AccessTemplate t) =>
      {'value': relay.accessTemplateToJson(t), 'reason': null};
  Map<String, Object?> auditEnvelope(relay.AuditQueryParams q) =>
      {'query': q.toJson()};

  // ------------------------------------------------------------------ arm 1
  test('ACCESS-01: a panel with no local database creates templates, binds '
      'keys, lists roles, creates a user and reads the audit trail over wss:// '
      '— and the rows land in the backend Postgres', () async {
    final (composed, panel) = await up(adminTok);
    addTearDown(() async {
      await panel.close();
      await composed.dispose();
    });

    final tplName = 'e2e-tpl-$suffix';
    // Encoded the client's way (value envelope) — decoded by access_handlers.
    await panel.request(relay.AccessMethods.templateCreate,
        params: templateEnvelope(AccessTemplate(
            name: tplName,
            rules: const {kWholeKeyMember: AccessGroup.setpoints})));
    await panel.request(relay.AccessMethods.templateBind, params: {
      'keyName': 'ST101.CN01.MOT01.speed',
      'templateName': tplName,
      'reason': null,
    });

    // Roles come back over the wire (read), and the created role is one of them.
    final roles = await panel.request(relay.AccessMethods.adminRoles) as List;
    expect(roles.map((r) => (r as Map)['name']), contains(adminRole),
        reason: 'roles() answered over the socket and named the seeded role');

    // Create a user through the pipe (NewUserParams.toJson, no envelope).
    final newUser = 'e2e-created-$suffix';
    await panel.request(relay.AccessMethods.adminCreateUser,
        params: relay.NewUserParams(
                subject: newUser,
                password: 'another-long-password-2',
                grantedRole: operRole)
            .toJson());

    // The audit read, query envelope.
    final audit = await panel.request(relay.AccessMethods.auditEntries,
        params: auditEnvelope(const relay.AuditQueryParams())) as List;
    expect(audit, isNotEmpty, reason: 'the audit trail answered over the wire');

    // The rows landed in Postgres — read back with SQL, not through the store.
    expect(
        await count("SELECT COUNT(*) AS c FROM access_template "
            "WHERE name = '$tplName'"),
        1,
        reason: 'the template the panel created over wss:// is in the backend '
            "Postgres — the panel has no database of its own, so this row "
            'could only have arrived through the socket');
    expect(
        await count("SELECT COUNT(*) AS c FROM app_user "
            "WHERE username = '$newUser'"),
        1,
        reason: 'the user the panel created over wss:// is in app_user');
  });

  // ------------------------------------------------------------------ arm 2
  test('ACCESS-03: every gateway write produced an audit_entry with '
      "origin='relay', who=the station account, station=the station; and a "
      'refused write left an allowed=false row', () async {
    final (composed, panel) = await up(adminTok);
    addTearDown(() async {
      await panel.close();
      await composed.dispose();
    });

    final before = await count(
        "SELECT COUNT(*) AS c FROM audit_entry WHERE $stationLike");

    // One permitted write.
    final okRole = 'E2E Ok $suffix';
    await panel.request(relay.AccessMethods.adminCreateRole,
        params: roleEnvelope(
            AccessRole(name: okRole, groups: const {AccessGroup.operate})));
    addTearDown(() => database.db
        .customStatement("DELETE FROM app_role WHERE name = '$okRole'"));

    // One refused write: an operate-only session asking to create a role.
    final (composedO, panelO) = await up(operTok);
    addTearDown(() async {
      await panelO.close();
      await composedO.dispose();
    });
    final denied = 'E2E Denied $suffix';
    final refusal = await panelO.refusal(relay.AccessMethods.adminCreateRole,
        params: roleEnvelope(
            AccessRole(name: denied, groups: const {AccessGroup.operate})));
    expect(refusal.code, _kForbidden,
        reason: 'an operate-only session was refused createRole by the server');

    final after = await count(
        "SELECT COUNT(*) AS c FROM audit_entry WHERE $stationLike");
    expect(after, greaterThan(before),
        reason: 'the decisions grew the trail; counted, not merely present');

    // Provenance of the allowed row, by SQL.
    expect(
        await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
            "$stationLike AND origin = 'relay' AND who = '$adminUser' "
            "AND allowed = true"),
        greaterThan(0),
        reason: "the allowed write's row names origin=relay, the verified "
            'station account, and allowed=true');

    // The refusal left an allowed=false row for the operate account.
    expect(
        await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
            "$stationLike AND origin = 'relay' AND who = '$operUser' "
            "AND allowed = false"),
        greaterThan(0),
        reason: 'the refused write left a deny row — the guard nobody can '
            'audit afterwards, closed (D-05)');

    // The refused role did NOT reach app_role.
    expect(
        await count("SELECT COUNT(*) AS c FROM app_role WHERE name = '$denied'"),
        0,
        reason: 'the refusal was pre-effect: no row was written');
  });

  // ------------------------------------------------------------------ arm 3
  test('ACCESS-05: the refusal is the SERVER\'s — a {operate} createRole frame '
      'is sent and refused server-side; and key_mappings needs configure '
      '(D-03), operate refused, {operate,configure} permitted', () async {
    final (composedO, panelO) = await up(operTok);
    addTearDown(() async {
      await panelO.close();
      await composedO.dispose();
    });

    // The client is not a security boundary: the raw panel always sends the
    // frame, and the server refuses it. A refusal measured by the client
    // declining to ask would prove nothing.
    final createRefusal = await panelO.refusal(
        relay.AccessMethods.adminCreateRole,
        params: roleEnvelope(AccessRole(
            name: 'E2E ServerRefused $suffix',
            groups: const {AccessGroup.operate})));
    expect(createRefusal.code, _kForbidden,
        reason: 'the server, not the client, refused createRole for {operate}');

    // D-03: key_mappings is graded configure. An operate-only session is
    // refused; an {operate,configure} session succeeds. Two sessions, one key.
    final kmRefusal = await panelO.refusal(relay.DataServiceMethods.prefSetString,
        params: {'key': 'key_mappings', 'value': '{"nodes":{}}'});
    expect(kmRefusal.code, _kForbidden,
        reason: 'operate-only may no longer save key_mappings over the wire '
            '(D-03) — the honest cost of one master policy');

    final (composedC, panelC) = await up(cfgTok);
    addTearDown(() async {
      await panelC.close();
      await composedC.dispose();
    });
    await panelC.request(relay.DataServiceMethods.prefSetString,
        params: {'key': 'key_mappings', 'value': '{"nodes":{}}'});
    // The permitted twin landed — read it back over the wire.
    final read = await panelC.request(relay.DataServiceMethods.prefGetString,
        params: {'key': 'key_mappings'});
    expect(read, '{"nodes":{}}',
        reason: 'an {operate,configure} session saved key_mappings — the '
            'anti-vacuity twin that proves the refusal is about the group');
  });

  // ------------------------------------------------------------------ arm 4
  group('ACCESS-04: the Server Config page follows the transport — the '
      'backend config surface over wss://, both polarities', () {
    // Phase 17's one named carry-forward (17-GATE.md): the shipped graph
    // served `backendConfig` sessionlessly from the shared source, which
    // refuses by name (-32011), because `IdentityAccessFamilies` carried no
    // config slot and wiring the store sessionlessly would forge D-11
    // attribution. These two arms are the fix's measurement: an authorised
    // station DOES the config work over the real wire, an unauthorised one is
    // REFUSED server-side — a fix that made both succeed would be worse than
    // the bug.

    /// The secret literals the stateman fixture carries. If either appears in
    /// a read frame, SECURITY FIX 3 (17-10) has regressed over the wire.
    const storedPassword = 'hunter2-e2e-very-secret';
    final storedKeyB64 = base64Encode(utf8.encode('FAKE-OPCUA-KEY-PEM-BYTES'));

    /// A parseable stateman file for the backend to serve: two OPC UA servers
    /// (one carrying credentials), and a `relay` section — readable, never
    /// writable over this socket (D-10).
    Map<String, Object?> statemanFixture() => {
          'opcua': <Object?>[
            <String, Object?>{
              'endpoint': 'opc.tcp://10.104.29.11:4840',
              'username': 'hmi',
              'password': storedPassword,
              'ssl_key': storedKeyB64,
              'server_alias': 'ST101',
            },
            <String, Object?>{
              'endpoint': 'opc.tcp://10.104.29.12:4840',
              'server_alias': 'ST201',
            },
          ],
          'jbtm': <Object?>[],
          'modbus': <Object?>[],
          'relay': {'port': 8787, 'token_file': tokenPath},
        };

    late String statemanPath;
    setUp(() {
      // A fresh file per arm: the authorised arm WRITES it, and the two arms
      // must not read each other's edits.
      statemanPath = '${tmp.path}/stateman-arm4-${Random().nextInt(1 << 20)}.json';
      File(statemanPath).writeAsStringSync(jsonEncode(statemanFixture()));
    });

    test('an administer-holding station reads, validates and WRITES the '
        'backend config over wss:// — the edit lands in the file on the '
        'backend, secrets stay redacted on the wire and preserved on disk, '
        'the relay section stays refused by name, and the audit rows name '
        'the verified station', () async {
      final (composed, panel) = await up(adminTok, statemanPath: statemanPath);
      addTearDown(() async {
        await panel.close();
        await composed.dispose();
      });

      final auditBefore = await count(
          "SELECT COUNT(*) AS c FROM audit_entry WHERE $stationLike "
          "AND surface = 'config'");

      // -- read: the gate's measured -32011 refusal is the failure this arm
      //    exists to catch; a green run means the per-identity config slot is
      //    wired on the shipped graph.
      final raw = await panel.request(relay.AccessMethods.configRead);
      final doc = relay.BackendConfigDocument.fromJson(
          (raw as Map).cast<String, Object?>());
      expect(doc.readOnlySections, contains('relay'),
          reason: 'the relay section is readable and flagged read-only so the '
              'screen greys it (D-10)');
      final decoded =
          jsonDecode(doc.configJson) as Map; // the document, as the screen sees it
      expect((decoded['relay'] as Map)['token_file'], tokenPath,
          reason: 'paths cross whole — the TlsConfig discipline (17-10)');
      expect(((decoded['opcua'] as List)[0] as Map)['endpoint'],
          'opc.tcp://10.104.29.11:4840',
          reason: 'the document is the real file, not an empty stub');

      // SECURITY FIX 3 over the real wire: neither secret literal is in the
      // full encoded frame; the sentinel stands in.
      final frame = jsonEncode(raw);
      expect(frame, isNot(contains(storedPassword)),
          reason: 'the OPC UA password must never cross the wire');
      expect(frame, isNot(contains(storedKeyB64)),
          reason: 'nor the private key bytes');
      expect(frame, contains(kSecretPreservedSentinel),
          reason: 'the sentinel marks the redacted values for the screen');

      // -- validate: a definite verdict for a bad document, never a write.
      final verdictRaw = await panel.request(relay.AccessMethods.configValidate,
          params: {'configJson': jsonEncode({...statemanFixture(), 'opcua': 42})});
      expect((verdictRaw as Map)['ok'], isFalse,
          reason: 'validate answers the parser verdict over the wire — the '
              'method the contract-kit parity sweep names as its gap, driven '
              'here on the shipped graph');

      // -- write: a benign edit through the sentinel round trip, exactly the
      //    screen's read-modify-write path.
      ((decoded['opcua'] as List)[1] as Map)['publishing_interval_ms'] = 400;
      await panel.request(relay.AccessMethods.configWrite,
          params: {'configJson': jsonEncode(decoded), 'reason': null});

      // The edit landed in the FILE the backend boots from — read off disk,
      // not through the socket, the ACCESS-01 "rows read by SQL" discipline.
      final onDisk = File(statemanPath).readAsStringSync();
      final diskDoc = jsonDecode(onDisk) as Map;
      expect(((diskDoc['opcua'] as List)[1] as Map)['publishing_interval_ms'],
          400,
          reason: 'the write crossed the wire and landed in the boot file');
      expect(onDisk, contains(storedPassword),
          reason: 'the sentinel resolved to the STORED secret — a round trip '
              'must not blank credentials (17-10 S2)');
      expect(onDisk, isNot(contains(kSecretPreservedSentinel)),
          reason: 'the marker never lands on disk as a literal credential');

      // Recoverability crossed the wire too.
      final after = relay.BackendConfigDocument.fromJson(
          ((await panel.request(relay.AccessMethods.configRead)) as Map)
              .cast<String, Object?>());
      expect(after.hasPrevious, isTrue,
          reason: 'the accepted write left a .previous to restore');

      // -- D-10 on the shipped wire: a relay-section edit is refused by name
      //    and the file does not move.
      final bytesBefore = File(statemanPath).readAsBytesSync();
      final tampered = jsonDecode(after.configJson) as Map;
      (tampered['relay'] as Map)['port'] = 9999;
      final relayRefusal = await panel.refusal(relay.AccessMethods.configWrite,
          params: {'configJson': jsonEncode(tampered), 'reason': null});
      expect(relayRefusal.message, contains('relay'),
          reason: 'the refusal names the section — you do not edit the socket '
              'over the socket (D-10)');
      expect(File(statemanPath).readAsBytesSync(), bytesBefore,
          reason: 'a refused write leaves the file byte-identical');

      // -- attribution, by SQL (ACCESS-06's config leg, unreachable until
      //    this fix): the accepted write's row names the VERIFIED station.
      //
      // Pinned to the STORE's own row — `item_key` is the boot file's path,
      // where the policy gate's twin row carries `state_man_config` — because
      // a sabotage round proved the loose form was satisfiable by the gate's
      // row while the store's carried a forged station.
      expect(
          await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
              "surface = 'config' AND item_key = '$statemanPath' "
              "AND origin = 'relay' AND who = '$adminUser' "
              "AND station = '$adminStation' AND allowed = true"),
          greaterThan(0),
          reason: 'the config write is attributed by the STORE to the '
              'server-verified station account (D-11) — the leg 17-GATE said '
              'rode this gap; a compose-time or payload-named station must '
              'not be able to hide behind the policy gate\'s own allow row');
      expect(
          await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
              "$stationLike AND surface = 'config'"),
          greaterThan(auditBefore),
          reason: 'the decisions grew the trail; counted, not merely present');
    });

    test('a station whose role lacks administer is REFUSED the config '
        'surface server-side (-32005) while its own permitted work still '
        'succeeds — and the file does not move', () async {
      // {operate, configure} — the SHARP negative: even the configure grade
      // does not reach the backend's own config, which sits at administer
      // (AccessPolicy, the `state_man_config` row).
      final (composed, panel) = await up(cfgTok, statemanPath: statemanPath);
      addTearDown(() async {
        await panel.close();
        await composed.dispose();
      });

      // Live control FIRST: this session is alive and authorised for its own
      // grade — the refusal below is about the group, not a broken session.
      await panel.request(relay.DataServiceMethods.prefSetString,
          params: {'key': 'key_mappings', 'value': '{"nodes":{}}'});

      final readRefusal =
          await panel.refusal(relay.AccessMethods.configRead);
      expect(readRefusal.code, _kForbidden,
          reason: 'reads are gated too — the document is the plant\'s server '
              'list and PLC addresses (ACCESS-05: the server refuses, the '
              'client is not the boundary)');

      final bytesBefore = File(statemanPath).readAsBytesSync();
      final writeRefusal = await panel.refusal(relay.AccessMethods.configWrite,
          params: {
            'configJson': jsonEncode(statemanFixture()),
            'reason': null
          });
      expect(writeRefusal.code, _kForbidden,
          reason: 'a configure-holding session may not write the backend '
              'config — administer is the grade');
      expect(File(statemanPath).readAsBytesSync(), bytesBefore,
          reason: 'the refused write left the boot file byte-identical');

      // The refusals left deny rows attributed to the refused account (D-05).
      expect(
          await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
              "$stationLike AND surface = 'config' AND who = '$cfgUser' "
              "AND allowed = false"),
          greaterThan(0),
          reason: 'a server-side refusal is a decision somebody can audit');
    });
  });

  // ------------------------------------------------------------------ arm 5
  test('ACCESS-06: a config write is attributable only to the server-verified '
      'station account; a client cannot name someone else', () async {
    final (composed, panel) = await up(adminTok);
    addTearDown(() async {
      await panel.close();
      await composed.dispose();
    });

    // The wire has no `who` field on any access method (D-11): the handler table
    // takes no such parameter, so a hand-rolled client has no field through
    // which to name somebody else. Submit a stray `who` on an audit read and a
    // create, and assert it changes no attribution: every relay row for this
    // station names the server-verified account, never the injected value.
    const forged = 'forged-somebody-else';
    final forgedRole = 'E2E Forge $suffix';
    // A stray `who` alongside the real envelope — the server must ignore it.
    await panel.request(relay.AccessMethods.adminCreateRole, params: {
      ...roleEnvelope(
          AccessRole(name: forgedRole, groups: const {AccessGroup.operate})),
      'who': forged,
      'actor': forged,
      'origin': 'operator',
    });
    addTearDown(() => database.db
        .customStatement("DELETE FROM app_role WHERE name = '$forgedRole'"));

    expect(
        await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
            "$stationLike AND who = '$forged'"),
        0,
        reason: 'no audit row was attributed to the client-supplied who — '
            'attribution is to the account the server verified at hello (D-11)');
    // And the real account is the one on the row for this action.
    expect(
        await count("SELECT COUNT(*) AS c FROM audit_entry WHERE "
            "$stationLike AND who = '$adminUser' AND origin = 'relay'"),
        greaterThan(0),
        reason: 'the verified station account is what the trail names');
  });

  // ------------------------------------------------------------------ arm 6
  group('revocation, end to end over the full wire', () {
    /// One tick of the embedder's poll: refresh the account cache (a DB-only
    /// demotion is invisible to the file digest), then sweep.
    Future<bool> poll(BackendRelayComposition composed) async {
      await composed.refreshAccounts();
      return composed.server.reloadTokensIfChanged();
    }

    test('a role demoted in app_role closes the live session with 4001 within '
        'one poll — the property that did not exist before this phase', () async {
      // A dedicated role/account so the demotion does not disturb the shared
      // seeds.
      final revRole = 'E2E Rev $suffix';
      final revUser = 'e2e-rev-$suffix';
      const revTok = 'e2e-rev-token-000000000000000';
      await repo.upsertRole(AccessRole(
          name: revRole,
          groups: const {AccessGroup.operate, AccessGroup.setpoints}));
      await repo.createUser(
          username: revUser, password: 'rev-long-password-3', roleName: revRole);
      await repo.setStationAccount(revUser, true);
      final revTokenPath = '${tmp.path}/rev-tokens.json';
      File(revTokenPath).writeAsStringSync(jsonEncode({
        'tokens': {
          revTok: {'username': revUser, 'station': 'E2Er$suffix'},
        },
      }));
      if (!Platform.isWindows) Process.runSync('chmod', ['600', revTokenPath]);
      // Registered role-first so it runs LAST: addTearDown is LIFO, and the
      // app_user → app_role foreign key means the user row must go first.
      addTearDown(() => database.db
          .customStatement("DELETE FROM app_role WHERE name = '$revRole'"));
      addTearDown(() => database.db.customStatement(
          "DELETE FROM app_user WHERE username = '$revUser'"));

      final config = RelayConfig.fromJson(<String, dynamic>{
        'relay': <String, dynamic>{
          'port': 0,
          'credentials': {'source': 'token_file', 'token_file': revTokenPath},
          'tls': {
            'chain_path': '${tmp.path}/chain.pem',
            'key_path': '${tmp.path}/key.pem'
          },
        },
      }, source: 'stateman.json')!;
      final composed = composeBackendRelay(
        config: config,
        pipe: PipeMainEndpoint(),
        keyMappings: _mappings(),
        database: database,
        prefs: prefs,
        log: Logger(level: Level.off),
      );
      await composed.refreshAccounts();
      await composed.server.start();
      final panel = await _Panel.connect(composed.server.port, caCertPem);
      await panel.hello(revTok);
      addTearDown(() async {
        await panel.close();
        await composed.dispose();
      });

      expect(await panel.stillAlive(), isTrue,
          reason: 'the station authenticated and is alive over wss://');

      // Demote: same role name, fewer groups. File untouched — the digest says
      // "no change", so the DB refresh on the same tick is what must catch it.
      await repo.upsertRole(
          AccessRole(name: revRole, groups: const {AccessGroup.operate}));
      final changed = await poll(composed);
      expect(changed, isFalse,
          reason: 'the file did not change; the demotion is invisible to its '
              'digest, which is why the DB refresh is load-bearing');

      expect(await panel.closeCode.timeout(const Duration(seconds: 8)),
          relay.CloseCodes.authExpired,
          reason: 'the demotion closed the live session with 4001 over the full '
              'wire, without a reconnect (D-08)');
    });

    test('ten unchanged polls close nothing — the anti-DoS half', () async {
      final (composed, panel) = await up(adminTok);
      addTearDown(() async {
        await panel.close();
        await composed.dispose();
      });
      for (var i = 0; i < 10; i++) {
        final changed = await poll(composed);
        expect(changed, isFalse, reason: 'nothing touched the file on tick $i');
        expect(await panel.stillAlive(), isTrue,
            reason: 'an unchanged tick must close nothing (tick $i)');
      }
      expect(panel.isClosed, isFalse);
    });

    test('a widened role also closes the session — 17-09 deviation 3, the '
        'whole-set compare retires on any change', () async {
      final wRole = 'E2E Widen $suffix';
      final wUser = 'e2e-widen-$suffix';
      const wTok = 'e2e-widen-token-0000000000000';
      await repo.upsertRole(
          AccessRole(name: wRole, groups: const {AccessGroup.operate}));
      await repo.createUser(
          username: wUser, password: 'widen-long-password-4', roleName: wRole);
      await repo.setStationAccount(wUser, true);
      final wPath = '${tmp.path}/widen-tokens.json';
      File(wPath).writeAsStringSync(jsonEncode({
        'tokens': {
          wTok: {'username': wUser, 'station': 'E2Ew$suffix'}
        }
      }));
      if (!Platform.isWindows) Process.runSync('chmod', ['600', wPath]);
      // Role-first registration so the user row (which references it) is
      // deleted first under addTearDown's LIFO order.
      addTearDown(() => database.db
          .customStatement("DELETE FROM app_role WHERE name = '$wRole'"));
      addTearDown(() => database.db
          .customStatement("DELETE FROM app_user WHERE username = '$wUser'"));

      final config = RelayConfig.fromJson(<String, dynamic>{
        'relay': <String, dynamic>{
          'port': 0,
          'credentials': {'source': 'token_file', 'token_file': wPath},
          'tls': {
            'chain_path': '${tmp.path}/chain.pem',
            'key_path': '${tmp.path}/key.pem'
          },
        },
      }, source: 'stateman.json')!;
      final composed = composeBackendRelay(
        config: config,
        pipe: PipeMainEndpoint(),
        keyMappings: _mappings(),
        database: database,
        prefs: prefs,
        log: Logger(level: Level.off),
      );
      await composed.refreshAccounts();
      await composed.server.start();
      final panel = await _Panel.connect(composed.server.port, caCertPem);
      await panel.hello(wTok);
      addTearDown(() async {
        await panel.close();
        await composed.dispose();
      });
      expect(await panel.stillAlive(), isTrue);

      await repo.upsertRole(AccessRole(
          name: wRole,
          groups: const {AccessGroup.operate, AccessGroup.setpoints}));
      await poll(composed);
      expect(await panel.closeCode.timeout(const Duration(seconds: 8)),
          relay.CloseCodes.authExpired,
          reason: 'the whole-set compare retires on any change; the panel '
              'reconnects into the widened identity (17-09 dev 3)');
    });
  });
}
