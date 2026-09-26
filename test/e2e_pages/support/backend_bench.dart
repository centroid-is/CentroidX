/// The real backend, over a real plant and a real Postgres, on a real socket.
///
/// ## Why this is not `plant_bench.dart`
///
/// `packages/tfc_relay_local/test/support/plant_bench.dart` is the pattern —
/// `tfc_plant_sim` under `buildGateway` under a `ws://` under a
/// `RemoteStateMan` — and it is the right bench for the transmission. It is
/// the wrong bench for the advanced pages, for one reason its own
/// `LocalStateMan` states in code: `audit`, `configItems`, `accessAdmin`,
/// `accessTemplates` and `backendConfig` are `_noAccessStore(...)` there
/// (`local_state_man.dart:1636-1642`). The pages under test here are those
/// stores. The graph that serves them is `composeBackendRelay`
/// (`packages/tfc_dart/lib/core/relay/backend_composition.dart`) — the one
/// function `centroidx-backend`'s `bin/main.dart` calls, whose composition test
/// asserts it is called exactly once — and this bench assembles that graph the
/// way the binary does: a `PipeMainEndpoint` fed by a real acquisition isolate
/// dialling a real OPC UA server, a `Database` over Postgres, the backend's
/// read-only shared preferences, a token file so `session.login` is wired, and
/// the account cache refreshed before the socket opens.
///
/// Nothing in between is a fake. Where a page's store has no wire behind it,
/// the page test says so rather than this bench pretending.
///
/// ## What is seeded, and why exactly this
///
/// * A first user, `eng`, holding Engineering — every group, so every raised
///   route opens for it. Made through `createFirstUser`, the commissioning
///   path, because a backend account cache that has never seen a user answers
///   `session.login` with the D-06 refusal, and that is a different finding.
/// * An operator, `op`, holding the seeded Operator role — `operate` alone.
///   The §10 control for every page: signed in, verified by the gateway, and
///   still without the route's group.
/// * The plant's key mappings, as `config_item` rows, written through a
///   station-shaped `ConfigStore` attached to the backend's database. That is
///   how rows get there in production (a station attaches and syncs), and it
///   is what `configItems.items` serves a browser.
/// * One alarm rule in `alarm_man_config`, through `SharedRowPreferences` over
///   the same store, so the alarm editor has a row to edit.
///
/// Nothing here throws out of a listener callback, for `ws_harness.dart`'s
/// reason: an exception raised there lands in the ambient isolate and
/// `package:test` attributes it to whichever case is running.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/audit_trail_store.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/config/config_change_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_rows.dart'
    show readSharedPreferenceValue, readSharedKeyMappingItems;
import 'package:tfc_dart/core/config/page_rows.dart' show readSharedPageItems;
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_shared_preferences.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings, OpcUANodeConfig, OpcUAConfig,
        StateManConfig;
import 'package:tfc_plant_sim/tfc_plant_sim.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart' show KeyPolicy;

import '../../helpers/test_helpers.dart' show FakeSecureStorage;
import 'postgres_fixture.dart';

/// The plant: one hall, the shapes the pages read, and one recording node.
///
/// `plant_bench.dart`'s spec, kept small for its reason: a case that needs a
/// second server asks for one. Alias and ids are what the key mappings and
/// every assertion spell, derived below rather than written twice.
const String kPlantSpec = '''
types:
  - name: RunMode
    kind: enum
    values: {0: fault, 1: stopped, 2: auto, 3: manual, 4: clean}
  - name: DriveStatus
    kind: struct
    members:
      - {name: run_mode, type: RunMode, value: 2}
      - {name: speed_hz, type: double, value: 50}
      - {name: fault_code, type: int, value: 0}
servers:
  - alias: HALL1
    nodes:
      - {id: CN01.speed_hz, type: double, motion: ramp, min: 0, max: 50, period: 100ms}
      - {id: CN01.drive, type: DriveStatus, motion: cycle, period: 300ms}
      - {id: CN01.setpoint_kg, type: double, value: 12.5, motion: once, records: true}
      - {id: CN01.rate, type: double, value: 0, motion: constant, period: 200ms}
      - {id: CN01.recipe_id, type: double, value: 7, motion: once}
''';

const String kHall = 'HALL1';
String plantKey(String nodeId) => '$kHall.$nodeId';

/// The accounts. Passwords long enough to be nobody's guess and short enough
/// to type into a dialog.
const String kEngineer = 'eng';
const String kEngineerPassword = 'eng-correct-horse-7';
const String kOperator = 'op';
const String kOperatorPassword = 'op-battery-staple-3';

/// The one alarm seeded for the editor to edit. The title is what the list
/// renders and what the round trip re-reads.
const String kSeededAlarmUid = 'e2e-alarm-1';
const String kSeededAlarmTitle = 'Rate above five';

/// Where a station's writes are attributed when they seed the plant.
const String kSeedStation = 'e2e-seed-station';

/// The surface the session's sign-in and sign-out rows carry
/// (`audit_trail_store.dart`'s private `_auditAuthSurface`).
const String kAuditAuthSurface = 'auth';

final class BackendBench {
  BackendBench._({
    required this.postgres,
    required this.plant,
    required this.database,
    required this.pipe,
    required this.worker,
    required this.composed,
    required this.statemanPath,
    required this.tokenPath,
    required this.keyMappings,
    required this.tmp,
  });

  final PostgresFixture postgres;
  final FakePlant plant;
  final Database database;
  final PipeMainEndpoint pipe;
  final DataAcquisitionWorker worker;
  final BackendRelayComposition composed;
  final String statemanPath;
  final String tokenPath;
  final KeyMappings keyMappings;
  final Directory tmp;

  /// The binary's revocation poll (`bin/main.dart:517-540`): every tick
  /// refreshes the account cache and reloads the token file if it changed.
  /// Without it an account created over the relay can never sign in — the
  /// cache the verifier resolves roles against was filled at boot. One
  /// second here where the binary's interval is the embedder's; the cadence
  /// is configuration, the poll is the design.
  Timer? _revocationPoll;

  /// The port the panel and the probe dial. Valid once `server.start()` has
  /// completed, which [standUp] awaits.
  int get port => composed.server.port;

  RunningServer get hall => plant.servers[kHall]!;

  /// The plant's count of writes at [nodeId] — the instrument a read-back
  /// cannot be (`plant_bench.dart`'s argument).
  int actuations(String nodeId) => hall.actuationCount(nodeId);

  AccessRepository get accounts => AccessRepository(database.db);

  AuditTrailStore get audit => AuditTrailStore(db: database.db);

  /// Every audit row, newest first — the decisions AND the sign-ins.
  ///
  /// `AuditQuery()` with no group names and `includeAuth: false` is the
  /// unfiltered read: the store's group legs are OR-ed, and `includeAuth:
  /// true` on its own is the leg that selects ONLY the auth rows
  /// (`audit_trail_store.dart:560-566`), which is the mistake this lane made
  /// first and every case's read-back would have inherited.
  Future<List<AuditRecord>> auditRows({String keyPrefix = ''}) =>
      audit.entries(AuditQuery(keyPrefix: keyPrefix));

  /// The rows about changes: everything but the sign-in/sign-out rows, which
  /// every panel and probe in this lane adds just by existing.
  Future<List<AuditRecord>> decisionRows({String keyPrefix = ''}) async =>
      (await auditRows(keyPrefix: keyPrefix))
          .where((r) => r.surface != kAuditAuthSurface)
          .toList();

  /// Every `config_change` row the backend holds, newest first.
  ///
  /// The direct reader, not the wire: this is what a case asserts the WIRE
  /// against, so it must not go through the thing under test.
  Future<List<ConfigChangeRecord>> configChangeRows() =>
      ConfigChangeStore(db: database.db)
          .changes(ConfigChangeQuery(limit: 500));

  /// A shared preference as the backend's own reader decodes it — the value a
  /// gateway panel is served, read straight off the row.
  Future<Object?> sharedPreference(String key) =>
      readSharedPreferenceValue(database.db, key);

  /// The stateman file the backend serves through `backendConfig.*`, decoded.
  Map<String, dynamic> statemanOnDisk() =>
      jsonDecode(File(statemanPath).readAsStringSync()) as Map<String, dynamic>;

  /// The plant's key mapping rows, as the backend would read them at boot.
  Future<List<ConfigItem>> keyMappingRows() =>
      readSharedKeyMappingItems(database.db);

  /// The plant's page rows — what `configItems.items('page')` serves.
  Future<List<ConfigItem>> pageRows() => readSharedPageItems(database.db);

  /// Writes one page row at the backend the way a station's save does, and
  /// returns its id. [pageJson] is `AssetPage.toJson()` from the app.
  Future<String> seedPage(String id, Map<String, dynamic> pageJson) async {
    final store = await _attachedStore();
    await store.inner.writeItems(
      kinds: const {ConfigKind.page},
      wanted: [
        ...await pageRows(),
        ConfigItem.of(kind: ConfigKind.page, id: id, value: pageJson),
      ],
      actionId: 'e2e-seed-page-$id',
      who: kEngineer,
      roleName: 'Engineering',
    );
    return id;
  }

  /// A second relay server over the SAME pipe and database, with [policy]
  /// in place of the shipped one. The shipped `AccessPolicyKeyPolicy` hides
  /// nothing, so a case about what a hidden key leaks needs a policy that
  /// hides one; `composeBackendRelay` takes the first composition's value
  /// source so the two servers do not each register a pipe callback
  /// (`backend_composition.dart`'s `values`/`freshness` rule).
  Future<BackendRelayComposition> secondServer({required KeyPolicy policy}) async {
    final stateman = statemanOnDisk();
    final prefs = await BackendSharedPreferences.create(database: database);
    final composed = composeBackendRelay(
      config: RelayConfig.fromJson(stateman, source: statemanPath)!,
      pipe: pipe,
      keyMappings: keyMappings,
      database: database,
      prefs: prefs,
      policy: policy,
      values: this.composed.liveValues,
      freshness: this.composed.freshness,
      statemanFilePath: statemanPath,
      log: Logger(level: Level.off),
    );
    await composed.refreshAccounts();
    await composed.server.start();
    return composed;
  }

  /// Makes the anonymous account grant NOTHING — the "NoOp anonymous row"
  /// §10 describes — so a socket that never signed in holds no group at all.
  Future<void> revokeAnonymous() async {
    final repo = accounts;
    await repo.upsertRole(const AccessRole(name: 'Nobody', groups: {}));
    await repo.setRole(kAnonymousUsername, 'Nobody');
    await composed.refreshAccounts();
  }

  /// Restores the seeded Operator floor for anonymous sessions.
  Future<void> restoreAnonymous() async {
    await accounts.setRole(kAnonymousUsername, kOperatorRoleName);
    await composed.refreshAccounts();
  }

  /// A station-shaped writer onto the backend's shared rows: what a direct
  /// station does when it attaches. Used to seed, and by cases that need a
  /// row to exist that no relayed path can write.
  Future<SharedRowPreferences> stationPreferences() async {
    final store = await _attachedStore();
    return SharedRowPreferences(
      store: store,
      secureStorage: FakeSecureStorage(),
      database: database,
    );
  }

  Future<GuardedConfigStore> _attachedStore() async {
    final local = AppDatabase.inMemoryForTest();
    final store = ConfigStore(
      local: local,
      stationScope: ConfigScope.forStation(kSeedStation),
      station: kSeedStation,
    );
    await store.open();
    store.attachRemoteDatabase(database.db, startSync: false);
    return GuardedConfigStore(
      inner: store,
      policy: const AccessPolicy(),
      session: () => const AccessSession(
        user: AuthenticatedUser(username: kEngineer, roleName: 'Engineering'),
        groups: {
          AccessGroup.operate,
          AccessGroup.configure,
          AccessGroup.administer,
          AccessGroup.users,
        },
      ),
      audit: _DiscardingSink(),
      station: kSeedStation,
    );
  }

  /// Stands everything up, in the binary's order, and returns once the socket
  /// is bound and the account cache holds the seeded users.
  ///
  /// [policy] lets a case swap the backend's key policy — the browse probe
  /// needs a policy that hides a key, and the shipped one hides nothing.
  static Future<BackendBench> standUp({KeyPolicy? policy}) async {
    // The backend's secrets live in the keychain in production; here the
    // keychain would outlive the process and re-ask on macOS. The composition
    // test makes the same substitution for the same reason.
    SecureStorage.setInstance(FakeSecureStorage());
    // Two drift classes over one Postgres — the backend's and the seeding
    // station's — is the shape production has (every station attaches to
    // the same database), and the warning is about a shared QueryExecutor,
    // which these do not share. `createTestConfigStore` silences it for the
    // same reason.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

    final postgres = await PostgresFixture.start();
    final tmp = Directory.systemTemp.createTempSync('e2e-pages-');

    // The plant first: the stateman file names its endpoint.
    final spec = PlantSpec.parse(kPlantSpec);
    final plant = await FakePlant.start(spec);
    final hall = plant.servers[kHall]!;

    final keyMappings = KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final server in spec.servers)
        for (final node in server.nodes)
          plantKey(node.id): KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(
                namespace: node.namespace, identifier: node.id)
              ..serverAlias = server.alias,
          ),
    });

    // The database, opened the way `Database.connectWithRetry` opens it
    // (`database.dart:312-330`): create, then `open()` — which is where a
    // fresh Postgres gets its schema and its seeded roles.
    final appDb = await AppDatabase.create(postgres.config);
    final database = Database(appDb);
    await database.db.open();

    // Accounts, through the same repository the backend's cache reads.
    final repo = AccessRepository(database.db);
    if (await repo.userCount() == 0) {
      await repo.createFirstUser(
          username: kEngineer, password: kEngineerPassword);
      await repo.createUser(
          username: kOperator,
          password: kOperatorPassword,
          roleName: kOperatorRoleName);
    }

    // The stateman file the backend reads and serves. Written with the
    // config classes' own `toJson`, so a renamed field renames here too.
    final tokenPath = '${tmp.path}/relay-tokens.json';
    File(tokenPath).writeAsStringSync(jsonEncode({'tokens': <String, Object?>{}}));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', tokenPath]);
    final opcua = OpcUAConfig()
      ..endpoint = hall.endpoint
      ..serverAlias = kHall
      ..enabled = true;
    final stateman = StateManConfig(opcua: [opcua]).toJson()
      ..['relay'] = <String, Object?>{
        'port': 0,
        'credentials': <String, Object?>{
          'source': 'token_file',
          'token_file': tokenPath,
        },
      };
    final statemanPath = '${tmp.path}/stateman.json';
    File(statemanPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(stateman));

    // The acquisition isolate: a REAL isolate with a REAL OPC UA client, on
    // the same Postgres, exactly as `bin/main.dart:252-267` spawns it.
    final pipe = PipeMainEndpoint();
    final worker = await spawnDataAcquisitionIsolate(
      server: opcua,
      dbConfig: postgres.config,
      keyMappings: keyMappings,
    );
    pipe.addWorker(AcquisitionWorkerLink(worker), keyMappings.nodes.keys);
    await worker.ready;

    final prefs = await BackendSharedPreferences.create(database: database);
    final relayConfig = RelayConfig.fromJson(stateman, source: statemanPath)!;
    final composed = composeBackendRelay(
      config: relayConfig,
      pipe: pipe,
      keyMappings: keyMappings,
      database: database,
      prefs: prefs,
      policy: policy,
      statemanFilePath: statemanPath,
      log: Logger(level: Level.off),
    );
    await composed.refreshAccounts();
    await composed.server.start();

    final bench = BackendBench._(
      postgres: postgres,
      plant: plant,
      database: database,
      pipe: pipe,
      worker: worker,
      composed: composed,
      statemanPath: statemanPath,
      tokenPath: tokenPath,
      keyMappings: keyMappings,
      tmp: tmp,
    );
    await bench._seedSharedRows();
    bench._revocationPoll = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        await composed.refreshAccounts();
        await composed.server.reloadTokensIfChanged();
      } on Object {
        // The binary's rule: a blinking database must not disconnect the
        // plant; the previously cached accounts are kept.
      }
    });
    return bench;
  }

  /// The rows a station would have written: key mappings and one alarm.
  Future<void> _seedSharedRows() async {
    final store = await _attachedStore();
    await store.inner.writeKeyMappings(keyMappings,
        actionId: 'e2e-seed-keys', who: kEngineer, roleName: 'Engineering');
    final prefs = SharedRowPreferences(
      store: store,
      secureStorage: FakeSecureStorage(),
      database: database,
    );
    final alarms = AlarmManConfig(alarms: [
      AlarmConfig(
        uid: kSeededAlarmUid,
        title: kSeededAlarmTitle,
        description: 'seeded by backend_bench.dart',
        rules: [
          AlarmRule(
            level: AlarmLevel.warning,
            expression: ExpressionConfig(
                value: Expression(formula: '${plantKey('CN01.rate')} > 5')),
            acknowledgeRequired: false,
          ),
        ],
      ),
    ]);
    await prefs.setString('alarm_man_config', jsonEncode(alarms.toJson()));
  }

  Future<void> tearDown() async {
    _revocationPoll?.cancel();
    await composed.dispose().catchError((Object _) {});
    pipe.shutdown();
    worker.kill();
    await database.close().catchError((Object _) {});
    await plant.close().catchError((Object _) {});
    await postgres.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

final class _DiscardingSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
}
