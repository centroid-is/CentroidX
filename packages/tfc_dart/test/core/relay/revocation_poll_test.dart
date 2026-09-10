/// The revocation poll the embedder was always supposed to own (17-11, D-08).
///
/// **The hole this file pins, measured 2026-09-07:** nothing in
/// `packages/*/lib`, `lib` or `bin` called `RelayServer.reloadTokensIfChanged()`
/// — only the declaration existed. `relay_server.dart` deliberately does not own
/// its own poll (the embedder owns configuration watching), and the embedder
/// never made the call. So in `centroidx-backend` as it shipped, pulling a
/// station's token off the disk changed nothing about the session it already
/// had, and a role demotion — which after Phase 17 also decides `configure` and
/// `administer` — took effect only on the next reconnect, which an operator can
/// postpone indefinitely by not reconnecting. That is the whole of SEC-03's
/// revocation clause not happening in production.
///
/// ## What is measured, and how
///
/// The behavioural arms compose the SHIPPING graph (`composeBackendRelay`, the
/// function `bin/main.dart` calls) over a real on-disk SQLite database and a
/// real token file, bind it on an OS-chosen port, connect a raw client socket,
/// and drive the poll **directly** — `composed.server.reloadTokensIfChanged()`,
/// after refreshing the account cache the way the embedder's tick does. No
/// wall-clock sleep is ever used as an assertion: a live session is proven alive
/// by a round-trip ping that returns, and a revoked one by its socket closing
/// with `4001 authExpired`. The `bin/main.dart` structural arms scan the source
/// for the poll and its shutdown-cancellation, because the defect being fixed is
/// *an absence*, and an absence needs a source-level pin or it comes back.
///
/// **Deviation from the plan, forced by the merged 17-09 surface (recorded so
/// the next reader is not surprised):** the plan (written before 17-09) assumed
/// a cached `GroupResolver` refreshed *inside* `reloadTokensIfChanged`. 17-04b
/// replaced that with `accounts: UserResolver`, a synchronous seam consulted
/// live by `stillValid` on every sweep. `reloadTokensIfChanged` lives in
/// `tfc_relay_server` and cannot reach back into this composition's account
/// cache, so the honest wiring is: the embedder's tick refreshes the cache
/// (`composed.refreshAccounts()`) and *then* calls
/// `composed.server.reloadTokensIfChanged()`. A database-only demotion is
/// invisible to the file digest, so the file re-parse is skipped while the DB
/// refresh runs every tick — a handful of rows by design.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup, AccessRole;
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../support/memory_secrets.dart';

// --------------------------------------------------------------- the fixture

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      'ST101.CN01.MOT01.speed': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'ST101.CN01')
          ..serverAlias = 'ST101',
      ),
    });

/// A raw panel socket in front of the bound server. Its only jobs are hello,
/// a liveness ping, and observing the close code.
final class _Panel {
  _Panel._(this._ws);

  final WebSocketChannel _ws;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Completer<int?> _closed = Completer<int?>();
  int _nextId = 1;
  Timer? _heartbeat;
  var _torn = false;

  static Future<_Panel> connect(int port) async {
    final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
    final panel = _Panel._(ws);
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

  /// The close code the client observed, once the socket closes.
  Future<int?> get closeCode => _closed.future;

  bool get isClosed => _closed.isCompleted;

  void _onFrame(Object? frame) {
    if (frame is! String) return;
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id is! int) return; // a server notification, not a reply
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (decoded['error'] != null) {
      completer.completeError(StateError('refused: ${decoded['error']}'));
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

  Future<Object?> _request(String method,
      {Object? params, Duration budget = const Duration(seconds: 5)}) {
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

  /// Says hello with [token] and starts the heartbeat pump so the reaper does
  /// not close the session out from under the poll (14-11's lesson).
  Future<relay.HelloResult> hello(String token) async {
    final raw = await _request(
      relay.Methods.hello,
      params: relay.HelloParams(
        protocol: relay.protocolVersion,
        supported: const [relay.protocolVersion],
        client: const relay.PeerInfo('revocation-poll-test', '0.1.0'),
        token: token,
      ).toJson(),
    );
    final result =
        relay.HelloResult.fromJson((raw as Map).cast<String, Object?>());
    final deadlineMs = result.heartbeatDeadlineMs;
    if (deadlineMs != null) {
      _heartbeat = Timer.periodic(Duration(milliseconds: deadlineMs ~/ 3), (_) {
        if (_torn || isClosed) return;
        unawaited(_request(relay.Methods.ping).catchError((Object _) => null));
      });
    }
    return result;
  }

  /// Proves the session is alive by a round-trip ping that returns — a positive
  /// liveness check rather than a wall-clock sleep. False when the socket is
  /// gone.
  Future<bool> stillAlive() async {
    if (isClosed) return false;
    try {
      await _request(relay.Methods.ping, budget: const Duration(seconds: 2));
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
  }
}

/// The shipping graph over a real DB and a real token file, bound, with a panel.
final class _Fixture {
  _Fixture._(this.composition, this.tokenPath, this.database);

  final BackendRelayComposition composition;
  final String tokenPath;
  final Database database;
  _Panel? panel;

  Future<_Panel> start(String token) async {
    // The embedder's own order: populate the account cache, then bind, so the
    // first hello can be resolved.
    await composition.refreshAccounts();
    await composition.server.start();
    final p = await _Panel.connect(composition.server.port);
    panel = p;
    await p.hello(token);
    return p;
  }

  /// One tick of the embedder's poll: refresh the account cache (a DB-only
  /// demotion is invisible to the file digest), then sweep.
  Future<bool> poll() async {
    await composition.refreshAccounts();
    return composition.server.reloadTokensIfChanged();
  }

  Future<void> dispose() async {
    await panel?.close();
    await composition.dispose();
  }
}

// ---------------------------------------------------------------------- arms

const _token = 'tok-st101-0000000000000000'; // 26 chars, past minTokenLength
const _username = 'ST101-panel';
const _station = 'ST101';
const _roleName = 'Revocation Test Role';

void main() {
  useMemorySecrets();

  late Directory tmp;
  late Database database;
  late Preferences prefs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('revocation-poll');
    database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'revocation-poll-test'),
      sqliteFolder: tmp,
    ));
    prefs = await Preferences.create(db: database);
  });

  tearDown(() async {
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Writes the one-station token file, locked to the owner.
  String writeTokenFile({bool withToken = true}) {
    final path = '${tmp.path}/relay-tokens.json';
    File(path).writeAsStringSync(jsonEncode(<String, dynamic>{
      'tokens': <String, dynamic>{
        if (withToken)
          _token: <String, dynamic>{'username': _username, 'station': _station},
      },
    }));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
    return path;
  }

  /// Seeds a role with [groups] and a station account holding it.
  Future<void> seed(Set<AccessGroup> groups) async {
    final repo = AccessRepository(database.db);
    await repo.upsertRole(AccessRole(name: _roleName, groups: groups));
    await repo.createUser(
        username: _username,
        password: 'a-long-enough-password',
        roleName: _roleName);
    await repo.setStationAccount(_username, true);
  }

  /// Changes the role's groups underneath a running gateway — a demotion or a
  /// widening, with the token file untouched.
  Future<void> setRoleGroups(Set<AccessGroup> groups) =>
      AccessRepository(database.db)
          .upsertRole(AccessRole(name: _roleName, groups: groups));

  _Fixture composeFixture(String tokenPath) {
    final config = RelayConfig.fromJson(<String, dynamic>{
      'relay': <String, dynamic>{
        'port': 0,
        'credentials': <String, dynamic>{
          'source': 'token_file',
          'token_file': tokenPath,
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
    final fx = _Fixture._(composed, tokenPath, database);
    addTearDown(fx.dispose);
    return fx;
  }

  // ------------------------------------------------------------------ arm 1
  //
  // Grep-level: the defect is an ABSENCE, and an absence needs a pin or it
  // comes back. bin/main.dart must call reloadTokensIfChanged. Anti-vacuity:
  // the file was found and is over 400 lines, so the assertion is against real
  // content rather than an empty read.
  group('the poll exists in the embedder', () {
    late String main;
    setUpAll(() => main = File('bin/main.dart').readAsStringSync());

    test('the scan reads the real file', () {
      expect(main, contains('void main()'));
      expect(main.split('\n').length, greaterThan(400));
    });

    test('bin/main.dart calls reloadTokensIfChanged exactly once', () {
      expect('reloadTokensIfChanged'.allMatches(main).length, 1,
          reason: 'D-08: the embedder owns the poll, and until this call '
              'existed revocation did not happen in production');
    });

    test('the poll uses reloadTokensIfChanged, not the always-reparsing '
        'reload()', () {
      // reloadTokens() (no "IfChanged") re-reads the file on every tick; the
      // digest-guarded sibling is what makes an unchanged file cost nothing.
      expect(RegExp(r'\breloadTokens\(\)').hasMatch(main), isFalse,
          reason: 'sabotage (d): a bare reload() re-parses every tick');
    });

    test('the tick is guarded — the poll call sits inside a try/catch OPENED '
        'inside the timer callback', () {
      // A throwing tick must not take the backend down (reload()'s own rule): a
      // rotation that produced a broken file, or a database that blinked, logs
      // and continues. The guard must live INSIDE the Timer.periodic callback,
      // because that callback runs asynchronously, long after — and outside the
      // dynamic extent of — the outer try that wraps the synchronous bind. A
      // sabotage that removed the callback's own try/catch left the call still
      // lexically inside the bind try and slipped past the naive scan; this arm
      // scans the callback body only. (Sabotage (h) turns this red.)
      final timerIndex = main.indexOf('Timer.periodic');
      expect(timerIndex, greaterThan(0),
          reason: 'the poll runs on a Timer.periodic');
      // Everything from the callback onward. The bind's outer `try {` is BEFORE
      // this point, so a `try {` found here is one opened inside the callback —
      // which is the only kind that guards the async tick.
      final fromTimer = main.substring(timerIndex);
      final tryIndex = fromTimer.indexOf('try {');
      final callIndex = fromTimer.indexOf('reloadTokensIfChanged');
      final catchIndex = fromTimer.indexOf('catch', callIndex);

      expect(callIndex, greaterThan(0), reason: 'the poll call is in the tick');
      expect(tryIndex, greaterThan(-1),
          reason: 'a try opened INSIDE the callback — not the bind try that '
              'wraps the synchronous setup, which does not guard an async tick '
              '(the finding sabotage h exposed)');
      expect(tryIndex, lessThan(callIndex),
          reason: 'the guard wraps the call, it does not follow it');
      expect(catchIndex, greaterThan(callIndex),
          reason: 'a catch that logs and continues follows the call');
    });

    test('the revocation timer is cancelled on shutdown', () {
      // A timer surviving shutdown is a process that never exits — this file
      // learned that once with the config-watch restart timer. Sabotage (i)
      // removes the cancel and this goes red.
      expect(main, contains('_revocationTimer'),
          reason: 'the timer is top-level so _shutdown can reach it');
      final shutdownStart = main.indexOf('void _shutdown(');
      expect(shutdownStart, greaterThan(0));
      // The cancel must appear inside _shutdown's body, before the next
      // top-level declaration.
      final shutdownBody = main.substring(
          shutdownStart, main.indexOf('void main()', shutdownStart));
      expect(shutdownBody.contains('_revocationTimer?.cancel()'), isTrue,
          reason: 'the poll timer is cancelled synchronously in _shutdown — no '
              'await, no close(), so the shutdown-structure arm still holds');
    });
  });

  // ------------------------------------------------------------- behavioural
  group('the shipping graph revokes a live session', () {
    test('a token removed from the file closes the session with 4001',
        () async {
      await seed({AccessGroup.operate});
      final path = writeTokenFile();
      final fx = composeFixture(path);
      final panel = await fx.start(_token);
      expect(await panel.stillAlive(), isTrue,
          reason: 'the station authenticated and is watching');

      // Pull the token off the disk, then poll.
      writeTokenFile(withToken: false);
      final changed = await fx.poll();
      expect(changed, isTrue, reason: 'the file bytes changed');

      expect(await panel.closeCode.timeout(const Duration(seconds: 5)),
          relay.CloseCodes.authExpired,
          reason: 'a revoked credential is told 4001, not serverDraining');
    });

    test('a role DEMOTED in app_role closes the session with 4001, file '
        'untouched — the case that never worked', () async {
      await seed({AccessGroup.operate, AccessGroup.setpoints});
      final path = writeTokenFile();
      final fx = composeFixture(path);
      final panel = await fx.start(_token);
      expect(await panel.stillAlive(), isTrue);

      // Demote: same role name, fewer groups. The token file is not rewritten,
      // so reloadIfChanged's digest says "no change" — the DB side of the tick
      // is what must catch this.
      await setRoleGroups({AccessGroup.operate});
      final changed = await fx.poll();
      expect(changed, isFalse,
          reason: 'the file did not change; the demotion is invisible to its '
              'digest, which is exactly why the DB refresh is load-bearing');

      expect(await panel.closeCode.timeout(const Duration(seconds: 5)),
          relay.CloseCodes.authExpired,
          reason: 'the demotion took effect without a reconnect (D-08, '
              'sabotage e)');
    });

    test('a role WIDENED also closes the session — merged whole-set compare '
        '(17-09 deviation 3)', () async {
      // DEVIATION: the plan wanted widening NOT to close. 17-04b's landed
      // stillValid compares the resolved group SET whole, so any edit to what
      // the role grants retires the session and it reconnects into a freshly
      // minted identity. A grant that took effect only at the panel's leisure
      // would be D-08's complaint mirrored. The anti-DoS property the plan is
      // really after — an UNCHANGED tick closes nothing — is arm 5 below.
      await seed({AccessGroup.operate});
      final path = writeTokenFile();
      final fx = composeFixture(path);
      final panel = await fx.start(_token);
      expect(await panel.stillAlive(), isTrue);

      await setRoleGroups({AccessGroup.operate, AccessGroup.setpoints});
      await fx.poll();

      expect(await panel.closeCode.timeout(const Duration(seconds: 5)),
          relay.CloseCodes.authExpired,
          reason: 'the whole-set compare retires on any change; the panel '
              'reconnects into the widened identity');
    });

    test('no change closes nothing — ten polls, and the session survives all '
        'ten', () async {
      await seed({AccessGroup.operate});
      final path = writeTokenFile();
      final fx = composeFixture(path);
      final panel = await fx.start(_token);

      for (var i = 0; i < 10; i++) {
        final changed = await fx.poll();
        expect(changed, isFalse, reason: 'nothing touched the file on tick $i');
        expect(await panel.stillAlive(), isTrue,
            reason: 'a sweep that closed the plant on every reload is the '
                'failure value-equality on the group set was written against '
                '(tick $i)');
      }
      expect(panel.isClosed, isFalse);
    });

    test('a failing tick keeps the previous set, and a later good tick still '
        'revokes', () async {
      await seed({AccessGroup.operate});
      final path = writeTokenFile();
      final fx = composeFixture(path);
      final panel = await fx.start(_token);

      // A tick that throws — the file is gone, as a half-written rotation would
      // leave it. The poll throws; the previously loaded set is kept.
      File(path).deleteSync();
      await expectLater(fx.poll(), throwsA(isA<Object>()),
          reason: 'reloadIfChanged surfaces the unreadable file');
      expect(await panel.stillAlive(), isTrue,
          reason: "reload()'s own rule: a rotation that produced a broken "
              'file must not disconnect the plant');

      // Anti-vacuity: a subsequent GOOD tick still revokes, so "kept the set"
      // is not "stopped working".
      writeTokenFile(withToken: false);
      await fx.poll();
      expect(await panel.closeCode.timeout(const Duration(seconds: 5)),
          relay.CloseCodes.authExpired);
    });
  });
}
