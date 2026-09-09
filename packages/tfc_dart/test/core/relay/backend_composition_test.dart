/// Criterion 4: **the composition the binary builds, assembled by a test.**
///
/// Phase 10's CR-01, restated by 13-CONTEXT: *"a composition nothing assembles
/// is a composition nothing tests, and it was the only one that shipped."*
/// Every collaborator in `lib/core/relay/` has been judged in isolation by its
/// own plan. None of that says anything about the object graph
/// `centroidx-backend` actually constructs — which, last milestone, was a graph
/// no test had ever built.
///
/// This file builds it. `composeBackendRelay` lives under `lib/` for the reason
/// `gateway_config.dart` records about `buildGateway`: **`bin/` is not
/// addressable by any `package:` URI**, so anything a test has to reach has to
/// live under `lib/`, and a structural arm below pins that `bin/main.dart`
/// reaches it exactly once. That pair — one function under `lib/`, one call
/// site in `bin/` — is the entire mechanism by which criterion 4 is satisfiable
/// at all.
///
/// ## The reader and the store are real
///
/// The `Database` and `Preferences` handed to the composition here are the
/// production classes over a real, on-disk SQLite `AppDatabase`
/// (`AppDatabase.create(..., sqliteFolder:)`, `database_drift.dart:915-923`) —
/// not a container, not a mock, not a `Fake…Source`. The plan permits a
/// database pointed at a test container and forbids a fake anything; SQLite is
/// the same production code path with a different executor behind drift, and it
/// runs on a machine with no Docker daemon, which is what this one is
/// (13-09 Finding 1). The no-fakes arm below asserts the runtime type of every
/// collaborator AND of the three sources behind the data services, so a fake
/// substituted anywhere fails with a type name in the message.
library;

import 'dart:convert' show jsonEncode;
import 'dart:io';
import 'dart:mirrors';

import 'package:logger/logger.dart';
import 'package:test/test.dart';

import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessPolicy, AccessSession, AuthenticatedUser;
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/access/local_auth_provider.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_access.dart'
    show BackendAccessAdmin, BackendAccessTemplates;
import 'package:tfc_dart/core/relay/backend_browse.dart';
import 'package:tfc_dart/core/relay/backend_composition.dart';
import 'package:tfc_dart/core/relay/backend_config_store.dart'
    show BackendConfigStore;
import 'package:tfc_dart/core/relay/backend_data_services.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_state_man.dart';
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/relay/key_mapping_series_resolver.dart';
import 'package:tfc_dart/core/relay/relay_config.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show WriteRejected;
import 'package:tfc_relay_server/tfc_relay_server.dart';

// --------------------------------------------------------------- the fixture

/// Three plant keys, spelled the way SVN spells them
/// (`svn-plc-tag-convention`): AREAnn.DEVnn.SUBnn.
KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in const <String>[
        'ST101.CN01.MOT01.speed',
        'ST101.CN01.MOT01.setpoint',
        'ST201.CN04.MOT01.running',
      ])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key)
            ..serverAlias = key.split('.').first,
        ),
    });

/// The `relay` section, as an operator would write it into the stateman file.
Map<String, dynamic> _relaySection({
  int port = 0,
  String? tokenFile,
  String source = 'none',
}) =>
    <String, dynamic>{
      'relay': <String, dynamic>{
        'port': port,
        'credentials': <String, dynamic>{
          'source': source,
          if (tokenFile != null) 'token_file': tokenFile,
        },
      },
    };

String _encode(Map<String, dynamic> json) => jsonEncode(json);

void main() {
  late Directory tmp;
  late Database database;
  late Preferences prefs;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('backend-composition');
    // The real production class over a real on-disk database. See the library
    // doc for why SQLite and not a container.
    database = Database(await AppDatabase.create(
      DatabaseConfig(applicationName: 'backend-composition-test'),
      sqliteFolder: tmp,
    ));
    prefs = await Preferences.create(db: database);
  });

  tearDown(() async {
    await database.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The graph, composed from the real everything. Torn down after the case.
  BackendRelayComposition compose({
    Map<String, dynamic>? stateman,
    KeyPolicy? policy,
    TokenValidator? validator,
    PipeMainEndpoint? pipe,
    KeyMappings? keyMappings,
    BackendLiveValues? values,
    BackendFreshnessSweep? freshness,
    String? statemanFilePath,
  }) {
    final config = RelayConfig.fromJson(
      stateman ?? _relaySection(),
      source: 'stateman.json',
    )!;
    final composed = composeBackendRelay(
      config: config,
      pipe: pipe ?? PipeMainEndpoint(),
      keyMappings: keyMappings ?? _mappings(),
      database: database,
      prefs: prefs,
      policy: policy,
      validator: validator,
      values: values,
      freshness: freshness,
      statemanFilePath: statemanFilePath,
      log: Logger(level: Level.off),
    );
    addTearDown(composed.dispose);
    return composed;
  }

  group('the graph the binary builds', () {
    test('is a RelayServer whose api is the backend adapter', () {
      final composed = compose();

      expect(composed.server, isA<RelayServer>());
      expect(composed.server.api, isA<BackendStateMan>(),
          reason: 'RelayServer takes a StateManApi and this phase supplies '
              'exactly one implementation of it');
      expect(identical(composed.server.api, composed.api), isTrue,
          reason: 'the adapter the record hands back must be the adapter the '
              'server holds, or the test is judging a second object');
    });

    test('returns the server UNSTARTED, so nothing binds a port here', () {
      final composed = compose();

      // `RelayServer.port` throws until start() has bound. The composition
      // returning unstarted is what lets bin/main.dart log the boot line
      // before it binds, and what lets every arm above run without a socket.
      expect(() => composed.server.port, throwsA(isA<StateError>()));
    });

    test(
        'is composed of the PRODUCTION classes, with no fake, stub or '
        'decorator standing in for one', () {
      final composed = compose();
      final api = composed.api;

      // One entry per collaborator in the graph. The role names are what a
      // failure message says, so a substitution is reported as "timeseries is
      // _FakeTimeseries" rather than as a set that differs somewhere.
      final actual = <String, Type>{
        'api': composed.server.api.runtimeType,
        'values (the sweep)': api.values.runtimeType,
        'values (the live half under it)': composed.liveValues.runtimeType,
        'writes': api.writes.runtimeType,
        'browse': api.browse.runtimeType,
        'timeseries': api.timeseries.runtimeType,
        'historyViews': api.historyViews.runtimeType,
        'preferences': api.preferences.runtimeType,
        'resolver': composed.server.resolver.runtimeType,
        'policy': composed.server.policy.runtimeType,
        // The three sources are the reader and the store themselves. Without
        // these three rows the arm would pass against a BackendTimeseries
        // composed over a fake TimeseriesSource — the production wrapper with
        // nothing real behind it, which is the exact shape CR-01 is about.
        //
        // Read by pattern and NOT by `as`: a cast would throw on a substituted
        // collaborator and report a cast error from a test line, before the map
        // below could name which role went wrong. The whole value of this arm
        // is the message it prints, so it must survive long enough to print it.
        'timeseries source': switch (api.timeseries) {
          BackendTimeseries(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
        'historyViews source': switch (api.historyViews) {
          BackendHistoryViews(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
        'preferences source': switch (api.preferences) {
          BackendPreferences(:final source) => source.runtimeType,
          final other => other.runtimeType,
        },
      };

      const reason =
          'Phase 10 CR-01: a composition nothing assembles is a composition '
          'nothing tests, and last milestone that was the only one that '
          'shipped. This arm asserts the runtime type of every collaborator '
          'in the graph bin/main.dart builds. A fake, a stub or a decorator '
          'substituted anywhere fails here with its own type name in the '
          'message — which is the only reason the list is worth writing down.';

      expect(actual, <String, Type>{
        'api': BackendStateMan,
        'values (the sweep)': BackendFreshnessSweep,
        'values (the live half under it)': BackendLiveValues,
        'writes': BackendWrites,
        'browse': BackendBrowse,
        'timeseries': BackendTimeseries,
        'historyViews': BackendHistoryViews,
        'preferences': BackendPreferences,
        'resolver': KeyMappingSeriesResolver,
        // 17-11: the policy is now the AccessPolicy-backed adapter, not the
        // deleted `AllVisibleOperatorWrites` — the write rule is stated once, in
        // the master `AccessPolicy`, and this class asks (17-07's overhaul).
        'policy': AccessPolicyKeyPolicy,
        'timeseries source': DatabaseTimeseriesSource,
        'historyViews source': DatabaseHistoryViewSource,
        'preferences source': PreferencesSource,
      }, reason: reason);

      // The plan's Set<Type> literal, kept alongside the per-role map: the map
      // names the offender, the set is the flat statement that no other type
      // appears in the graph at all.
      expect(actual.values.toSet(), <Type>{
        BackendStateMan,
        BackendFreshnessSweep,
        BackendLiveValues,
        BackendWrites,
        BackendBrowse,
        BackendTimeseries,
        BackendHistoryViews,
        BackendPreferences,
        KeyMappingSeriesResolver,
        AccessPolicyKeyPolicy,
        DatabaseTimeseriesSource,
        DatabaseHistoryViewSource,
        PreferencesSource,
      }, reason: reason);
    });

    test('the freshness sweep wraps the live half, not the other way round',
        () {
      final composed = compose();

      expect(identical(composed.api.values, composed.freshness), isTrue,
          reason: 'the adapter must read through the sweep, or a value that '
              'has gone quiet is served to a panel still badged good');
    });

    // The arm that would have caught rig probe P4a before the rig did. Every
    // arm above judges the SHAPE of the graph; this one drives a write through
    // it, because the guard that was missing is invisible to a type map — the
    // production `BackendWrites` was in the graph, correctly, with an empty
    // idea of which keys are read-modify-writes.
    test('a blind array-element write is refused by the graph the binary '
        'builds', () async {
      final composed = compose(
        keyMappings: KeyMappings(nodes: <String, KeyMappingEntry>{
          'ST101.CN01.MOT01.trim.1': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MAIN.rData')
              ..arrayIndex = 0,
          ),
        }),
      );

      final result = await composed.api
          .write('ST101.CN01.MOT01.trim.1', 1234.5, cmd: 'p4a-composed-1');

      expect(result, isA<WriteRejected>(),
          reason: 'the guard has to be WIRED, not merely implemented. On the '
              'rig this exact write answered {"outcome":"applied"} against a '
              'real PLC array');
      expect((result as WriteRejected).reason.kind,
          'array_element_requires_expect');
      // No worker was ever registered on this pipe, so the router owns nothing
      // — and the answer is still the guard's rather than `unrouted`. That is
      // the ordering being pinned: the refusal happens before anything is sent
      // anywhere, which is the only place a read-modify-write can be refused
      // without having already run.
      expect((result).reason.kind, isNot('unrouted'));
    });
  });

  group('the policy is named at the call site, not defaulted', () {
    test('the shipped policy is the one this composition names', () {
      final composed = compose();

      // IDENTITY, not type. `RelayServer`'s default is
      // `const AllVisibleOperatorWrites()`, and Dart canonicalises const
      // instances — so an explicit `policy: const AllVisibleOperatorWrites()`
      // and no argument at all are the same object and indistinguishable by
      // any assertion about type or equality. `backendRelayPolicy` is a
      // deliberately non-const instance for exactly this reason: it is what
      // makes "somebody chose this" a fact a test can read.
      expect(identical(composed.server.policy, backendRelayPolicy), isTrue,
          reason: 'a default that ships is a decision nobody made. The policy '
              'must be the instance backend_composition.dart names, with its '
              'reason written beside it');
      expect(identical(composed.server.policy, const AccessPolicyKeyPolicy()),
          isFalse,
          reason: 'if this is the canonicalised const `AccessPolicyKeyPolicy` '
              'that RelayServer defaults to (relay_server.dart:152), the '
              'composition let RelayServer default and the arm above is '
              'vacuous. `backendRelayPolicy` is a deliberately non-const '
              'instance so "somebody chose it" is a fact a test can read by '
              'identity');
      expect(composed.server.policy, isA<AccessPolicyKeyPolicy>(),
          reason: '17-11: the shipped policy is the AccessPolicy-backed adapter '
              '(17-07), not the deleted AllVisibleOperatorWrites');
    });

    test('a deployment may hand its own policy in, and it is the one used', () {
      final mine = AccessPolicyKeyPolicy(policy: const AccessPolicy());
      final composed = compose(policy: mine);

      expect(identical(composed.server.policy, mine), isTrue);
    });
  });

  group('one credential source, and never two', () {
    test('a token file produces ServerConfig.auth and NO validator argument',
        () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');
      final composed = compose(
        stateman: _relaySection(source: 'token_file', tokenFile: tokens.path),
      );

      expect(composed.server.config.auth, isNotNull);
      expect(composed.server.config.auth!.tokenFilePath, tokens.path);
      // Reaching this line at all is the assertion: RelayServer's constructor
      // throws when it is given both (relay_server.dart:155), so a composition
      // that passed a validator alongside auth could not have been built.
    });

    test('handing a validator alongside a token file is refused HERE, before '
        'RelayServer can throw it at boot', () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');

      expect(
          () => compose(
                stateman: _relaySection(
                    source: 'token_file', tokenFile: tokens.path),
                validator: const PermissiveTokenValidator(),
              ),
          throwsA(isA<ArgumentError>()),
          reason: 'the composition refuses the pair rather than forwarding it, '
              'so the message names the composition root rather than arriving '
              'from relay_server.dart:155 in a container log at 03:00');
    });

    test('the ArgumentError at relay_server.dart:155 really does fire, so the '
        'arm above is not vacuous', () {
      final tokens = File('${tmp.path}/relay-tokens.json')
        ..writeAsStringSync('{"tokens":[]}');
      final config = RelayConfig.fromJson(
        _relaySection(source: 'token_file', tokenFile: tokens.path),
        source: 'stateman.json',
      )!;

      // The deliberately-wrong construction, by hand: the exact pair the
      // composition declines to build.
      //
      // **A NON-const `PermissiveTokenValidator`, and that matters.**
      // `RelayServer` tells "you configured nothing" from "you configured a
      // validator" by IDENTITY against `RelayServer.permissiveDefault`, which
      // IS `const PermissiveTokenValidator()` — Dart canonicalises const
      // instances, so passing the const spelling reads as having configured
      // nothing and does NOT throw. Measured, not assumed: this arm was
      // written with `const` first and passed against the pair it exists to
      // refuse. It is also why `composeBackendRelay` refuses on `!= null`
      // rather than leaning on the server's identity check — a caller could
      // otherwise hand it the canonicalised const and be silently read as
      // having handed nothing.
      expect(
          () => RelayServer(
                api: BackendStateMan(),
                config: config.toServerConfig(),
                // ignore: prefer_const_constructors
                validator: PermissiveTokenValidator(),
                resolver: KeyMappingSeriesResolver(keyMappings: _mappings()),
              ),
          throwsA(isA<ArgumentError>().having((e) => e.message.toString(),
              'message', contains('sources of truth'))),
          reason: 'if this stopped throwing, every credential arm above would '
              'pass against a server that quietly accepted two credential '
              'sources');
    });

    test('a validator deployment must be handed one, and is refused without',
        () {
      expect(
          () => compose(stateman: _relaySection(source: 'validator')),
          throwsA(isA<ArgumentError>()),
          reason: 'credentials.source = validator says the composition root '
              'supplies the check; a root that supplies none would serve the '
              'plant LAN with RelayServer\'s permissive default');
    });
  });

  // ------------------------------------------------ the RBAC access surface
  //
  // 17-11: the shipping graph carries the real audit SINK, the real database
  // group resolver and the per-identity family factory — assembled by this
  // test, not by fakes behind decorators (CR-01). Every arm reads a runtime
  // type or a live answer off the graph `bin/main.dart` builds.
  //
  // **Deviation forced by the merged 17-09 surface, recorded here so the next
  // reader is not surprised:** the plan (written before 17-09) wanted the four
  // access families wired into the shared `BackendStateMan` and reachable
  // through `composed.api.accessTemplates` etc. 17-09 landed a different seam:
  // `accessTemplates`/`accessAdmin` are built PER IDENTITY at `hello` through
  // `RelayServer.accessFor` (a callback the shared source cannot hold, because
  // a compose-time family would forge attribution — D-11), and only the
  // sessionless `audit` family lives on the shared source. So "reachable" is
  // asserted where each family actually lives: the audit family and sink on the
  // shared graph, the two scoped families through the factory.

  /// A token file locked to the owner — the only mode the loader accepts.
  String _tokenFile(String username, String station) {
    final path = '${tmp.path}/relay-tokens.json';
    File(path).writeAsStringSync(jsonEncode(<String, dynamic>{
      'tokens': <String, dynamic>{
        // 24+ chars: FileTokenValidator.minTokenLength.
        'tok-${station.toLowerCase()}-000000000000000': <String, dynamic>{
          'username': username,
          'station': station,
        },
      },
    }));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
    return path;
  }

  /// Creates a station account holding [roleName] and returns its username.
  Future<String> _seedStation(String username, String roleName) async {
    final repo = AccessRepository(database.db);
    await repo.createUser(
        username: username, password: 'a-long-enough-password', roleName: roleName);
    await repo.setStationAccount(username, true);
    return username;
  }

  group('the shipping graph carries the real sink, resolver and factory', () {
    test('the audit SINK RelayServer writes verdicts to is a DriftAuditSink '
        'over the backend own database', () {
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file',
            tokenFile: _tokenFile('ST101-panel', 'ST101')),
      );

      expect(composed.server.audit, isA<DriftAuditSink>(),
          reason: 'a wire authorization verdict must land in the same '
              'audit_entry table the panel writes to — NullAuditSink would '
              'degrade the trail to nothing (CR-01, sabotage a)');
    });

    test('a token file requires — and the composition wires — an account '
        'resolver over app_role', () async {
      final user = await _seedStation('ST101-panel', 'Shift Leader');
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file', tokenFile: _tokenFile(user, 'ST101')),
      );
      // The resolver cache is populated by the poll before the first hello;
      // the composition exposes the same refresh the embedder drives.
      await composed.refreshAccounts();

      final resolver = composed.server.accounts;
      expect(resolver, isNotNull,
          reason: 'RelayServer.start() REFUSES a token file with no resolver '
              '(relay_server.dart:496); a composition that shipped one would '
              'not start');

      final resolved = resolver!(user);
      expect(resolved, isNotNull,
          reason: 'the station account seeded above must resolve');
      expect(resolved!.groups, contains(AccessGroup.setpoints),
          reason: 'Shift Leader carries operate+setpoints; the groups come '
              'from app_role, read through AccessRepository, not from the file');
      expect(resolver('nobody-at-all'), isNull,
          reason: 'an unknown username resolves to null, never to an empty '
              'group set — D-06 fail-closed');
    });

    test('a token file composition wires the sign-in verifier — increment B: '
        'the decorator wraps at start() and a person can sign in over the '
        'socket', () async {
      final user = await _seedStation('ST101-panel', 'Shift Leader');
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file', tokenFile: _tokenFile(user, 'ST101')),
      );
      expect(composed.server.loginVerifier, isA<LocalAuthProvider>(),
          reason: 'session.login verifies through the SAME AuthProvider seam '
              'the panel used in direct mode, over the backend\'s own '
              'AccessRepository — one master access system, no second '
              'verification path. Without this the gateway refuses every '
              'sign-in by name and the ruling\'s increment B never reaches '
              'the plant');
    });

    test('the per-identity template and admin families are built by the '
        'factory, as the real backend classes', () {
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file',
            tokenFile: _tokenFile('ST101-panel', 'ST101')),
      );

      final factory = composed.server.accessFor;
      expect(factory, isNotNull,
          reason: 'templates/admin are minted per verified identity (D-11); '
              'the factory is the seam 17-09 built and 17-11 fills');

      const user = AuthenticatedUser(
          username: 'ST101-panel',
          roleName: 'Shift Leader',
          stationAccount: true);
      const identity = StationIdentity(
        user: user,
        station: 'ST101',
        session: AccessSession(
            user: user, groups: {AccessGroup.operate, AccessGroup.setpoints}),
      );
      final families = factory!(identity);

      expect(families.accessTemplates, isA<BackendAccessTemplates>(),
          reason: 'the real store-backed family, not a fake behind a decorator');
      expect(families.accessAdmin, isA<BackendAccessAdmin>(),
          reason: 'and the admin family with it');
    });

    test('the factory also mints the per-identity backendConfig family — a '
        'BackendConfigStore over the boot file the composition was handed '
        '(the 17-GATE carry-forward: -32011 on the wire until this exists)',
        () async {
      // A parseable stateman file for the store to serve, relay section
      // included so the read can flag it read-only (D-10).
      final statemanPath = '${tmp.path}/stateman-config-arm.json';
      File(statemanPath).writeAsStringSync(jsonEncode(<String, dynamic>{
        'opcua': <Object?>[],
        'jbtm': <Object?>[],
        'modbus': <Object?>[],
        'relay': <String, dynamic>{
          'port': 8787,
          'token_file': '/etc/centroid/relay-tokens.json',
        },
      }));
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file',
            tokenFile: _tokenFile('ST101-panel', 'ST101')),
        statemanFilePath: statemanPath,
      );

      const user = AuthenticatedUser(
          username: 'ST101-panel',
          roleName: 'Shift Leader',
          stationAccount: true);
      const identity = StationIdentity(
        user: user,
        station: 'ST101',
        session: AccessSession(
            user: user, groups: {AccessGroup.operate, AccessGroup.setpoints}),
      );
      final families = composed.server.accessFor!(identity);

      expect(families.backendConfig, isA<BackendConfigStore>(),
          reason: 'the real file-backed store, minted per verified identity — '
              'a compose-time store would have no session to attribute rows '
              'to (D-11), and no store at all is the -32011 the gate measured');
      final doc = await families.backendConfig!.read();
      expect(doc.readOnlySections, contains('relay'),
          reason: 'the store serves the handed boot file with 17-10\'s D-10 '
              'semantics intact');
    });

    test('with no boot file handed to the composition, the config family '
        'refuses by name — never a stub that quietly succeeds', () async {
      final composed = compose(
        stateman: _relaySection(
            source: 'token_file',
            tokenFile: _tokenFile('ST101-panel', 'ST101')),
        // statemanFilePath deliberately absent.
      );
      const user = AuthenticatedUser(
          username: 'ST101-panel',
          roleName: 'Shift Leader',
          stationAccount: true);
      const identity = StationIdentity(
        user: user,
        station: 'ST101',
        session: AccessSession(
            user: user, groups: {AccessGroup.operate, AccessGroup.setpoints}),
      );
      final families = composed.server.accessFor!(identity);

      await expectLater(
          families.backendConfig!.read(),
          throwsA(isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('CENTROID_STATEMAN_FILE_PATH'))),
          reason: 'fail closed, and the refusal names the thing that is '
              'missing — "no servers configured" and "nobody wired a path" '
              'must not look the same from a screen (17-10)');
    });

    test('bin/main.dart hands the boot file to composeBackendRelay — the '
        'shipped binary, not just this fixture', () {
      // The source arm the revocation-poll test established for D-08: the
      // wiring must exist in the binary the plant runs, or the E2E is green
      // while every real panel still gets -32011.
      final src = File('bin/main.dart').readAsStringSync();
      expect(
          RegExp(r'statemanFilePath:\s*statemanConfigFilePath')
              .hasMatch(src),
          isTrue,
          reason: 'the relay block must pass the CENTROID_STATEMAN_FILE_PATH '
              'file it already reads into composeBackendRelay, or the config '
              'family refuses by name on the shipped backend');
    });

    test('an off-by-default composition (no token file) wires no resolver and '
        'no factory, and still carries the real sink', () {
      final composed = compose();

      expect(composed.server.accounts, isNull,
          reason: 'a `none` credential source names no accounts to resolve; a '
              'resolver here would be answering a question nobody asked');
      expect(composed.server.loginVerifier, isNull,
          reason: 'and no sign-in verifier either: with no account cache the '
              'login handler could resolve nothing, and RelayServer.start '
              'gates the credential-less-admission wrap on the verifier — '
              'null here is what keeps a `none` gateway\'s hello surface '
              'byte-identical to what it was');
      // The audit sink is real whether or not credentials are configured: the
      // trail is not a function of who authenticated.
      expect(composed.server.audit, isA<DriftAuditSink>());
    });
  });

  group('the resolver is built from the keys the workers were registered with',
      () {
    test('it is a KeyMappingSeriesResolver over the same mappings', () {
      final mappings = _mappings();
      final composed = compose(keyMappings: mappings);
      final resolver = composed.server.resolver;

      expect(resolver, isA<KeyMappingSeriesResolver>());
      for (final key in mappings.nodes.keys) {
        expect(resolver.keyForNode(key), key,
            reason: 'a resolver built from different mappings than the pipe\'s '
                'workers is a chart that resolves to a table nobody writes');
      }
      expect(resolver.keyForNode('ST999.CN99.MOT99.speed'), isNull);
    });
  });

  group('the graph actually serves', () {
    test('start() binds a port and close() gives it back', () async {
      final composed = compose(stateman: _relaySection(port: 0));

      await composed.server.start();
      expect(composed.server.port, greaterThan(0),
          reason: 'port 0 draws a free port; a graph that cannot bind is a '
              'graph that has never been shown to serve');
      // Closed by the composition's own dispose (addTearDown in `compose`).
    });
  });

  // ------------------------------------------------------- the carried finding

  group('FINDING: the preferences allow-list narrowing has no home here', () {
    // 13-05 flagged it, 13-06 routed it to this plan's `policy:` argument, and
    // this plan measured that the routing does not work. Both arms below are
    // the finding written as executable statements rather than as prose in a
    // SUMMARY nobody re-reads. Neither changes behaviour; see 13-10-SUMMARY.

    test('KeyPolicy now carries canWritePreference — the narrowing found its '
        'home in 17-07, not in this composition', () {
      final declared = reflectClass(KeyPolicy)
          .declarations
          .values
          .whereType<MethodMirror>()
          .where((m) => !m.isConstructor && !m.isStatic)
          .map((m) => MirrorSystem.getName(m.simpleName))
          .toSet();

      // UPDATED FOR 17-07 (was `{canSee, canWrite}`). The prior arm pinned the
      // ABSENCE of a preference member and pointed here: "If this arm is red
      // because somebody added that member, the narrowing finally HAS a home."
      // 17-07 added `canWritePreference`, graded by key from the app's own
      // `kPrefAccessRules` (key_policy.dart:149-172), so the finding 13-05/13-06
      // flagged is answered in the MASTER policy layer — exactly where Phase
      // 17's constitution says one access-control system lives — rather than in
      // this composition's `policy:` argument. The residual `clear(allowList:)`
      // exposure the second arm measures is a separate, still-open hole in
      // tfc_relay_server's `_PolicyPreferences`, not this member's concern.
      expect(declared, <String>{'canSee', 'canWrite', 'canWritePreference'},
          reason: 'KeyPolicy is the AccessPolicy-backed adapter now; a fourth '
              'member appearing here is a new policy surface somebody must '
              'decide the composition passes data for');
    });

    test('an allow-listed clear naming key_mappings still deletes it — the '
        'residual exposure, measured', () async {
      final composed = compose();
      final preferences = composed.api.preferences;

      await preferences.setString('key_mappings', '{"nodes":{}}');
      await preferences.setString('svn.chart.maxPoints', '6000');
      expect(await preferences.containsKey('key_mappings'), isTrue);

      // An UNRESTRICTED clear never reaches here on the wire: _PolicyPreferences
      // .clear refuses `allowList == null` pre-effect (policy_state_man.dart:
      // 1072-1086, 10-REVIEW CR-02), and PolicyStateMan wraps every session
      // unconditionally (relay_session.dart:362) regardless of what `policy:`
      // is. 13-05's and 13-06's hand-forward was written without that fact.
      //
      // What IS still reachable is this: an `operate` session naming the
      // reserved key in its own allow list. `reservedPreferenceKeys`
      // (policy_state_man.dart:95) is quoted in the refusal MESSAGE and is
      // never enforced as an exclusion.
      await preferences.clear(allowList: <String>{'key_mappings'});

      expect(await preferences.containsKey('key_mappings'), isFalse,
          reason: 'THIS IS THE FINDING, not the desired behaviour. 518 KiB of '
              'routing configuration the whole plant is served through, gone '
              'in one gated call, not restored by reconnecting, and not '
              'visible until the next restart. Fixing it is a change to '
              'tfc_relay_server\'s policy layer — enforce '
              'reservedPreferenceKeys as an exclusion, or grow the member the '
              'arm above pins the absence of. It is NOT a change this '
              'composition can make: see 13-10-SUMMARY.');
      expect(await preferences.containsKey('svn.chart.maxPoints'), isTrue,
          reason: 'the allow list is honoured, which is why the call is not '
              'simply broken — it is precise, and that is what makes it '
              'usable as a weapon');
    });
  });

  group('off by default, and it is the upgrade-safety property', () {
    // Both directions, through the same call bin/main.dart makes, on a real
    // file. The structural arms below prove where the guard is; these two prove
    // what it is guarding on.

    Future<RelayBoot> bootFrom(Map<String, dynamic> stateman) {
      final file = File('${tmp.path}/stateman.json')
        ..writeAsStringSync(_encode(stateman));
      return RelayBoot.fromStatemanFile(file.path);
    }

    test('a stateman file with no relay section: OFF, one line, no throw',
        () async {
      final boot = await bootFrom(<String, dynamic>{
        'opcua': <dynamic>[],
        'modbus': <dynamic>[],
      });

      expect(boot.isOn, isFalse);
      expect(boot.config, isNull,
          reason: 'a null config is what makes the relay block in '
              'bin/main.dart unreachable. Every plant backend at SVN gets this '
              'binary before anybody turns the WebSocket on, and it must boot '
              'exactly as it does today');
      expect(boot.bootLogLine, contains('OFF'));
      expect(boot.bootLogLine.split('\n'), hasLength(1),
          reason: 'one line an operator can read off a boot log');
    });

    test('the same file with a relay section: ON, and it composes', () async {
      final boot = await bootFrom(<String, dynamic>{
        'opcua': <dynamic>[],
        ..._relaySection(port: 0),
      });

      expect(boot.isOn, isTrue);
      expect(boot.bootLogLine, contains('ON'));
      final composed = composeBackendRelay(
        config: boot.config!,
        pipe: PipeMainEndpoint(),
        keyMappings: _mappings(),
        database: database,
        prefs: prefs,
        log: Logger(level: Level.off),
      );
      addTearDown(composed.dispose);
      expect(composed.server, isA<RelayServer>(),
          reason: 'without this half the OFF arm above would pass against a '
              'backend that can never turn the relay on at all');
    });
  });

  // ------------------------------------------------ the hoisted value source

  group('the value source may be supplied, because alarms outlive the relay',
      () {
    // 14-08. The relay is off by default and SVN runs that way today, so a
    // value source built HERE exists only when a WebSocket is configured — and
    // the alarm engine feeding from it would go dark exactly where this phase
    // is aimed (P-5). `bin/main.dart` therefore builds the pair itself, before
    // the relay guard, and hands it in.

    test('a supplied pair is the pair the graph uses, and no second one is '
        'built', () {
      final pipe = PipeMainEndpoint();
      final keyMappings = _mappings();
      final values = BackendLiveValues(
        pipe: pipe,
        keyMappings: keyMappings,
        logger: Logger(level: Level.off),
      );
      final freshness = BackendFreshnessSweep(
        values: values,
        staleAfter: values.staleAfter,
        pipe: pipe,
        logger: Logger(level: Level.off),
      );
      // The obligations both objects wired in their own constructors. If the
      // composer builds a second pair, these fields point at the second one
      // afterwards and the first pair goes deaf — silently, which is the whole
      // hazard.
      final retired = pipe.onKeyRetired;
      final died = pipe.onWorkerDied;
      final ready = pipe.onWorkerReady;

      final composed = compose(
        pipe: pipe,
        keyMappings: keyMappings,
        values: values,
        freshness: freshness,
      );

      expect(identical(composed.liveValues, values), isTrue,
          reason: 'the composition must surface the live half it was given, '
              'not one it made. Criterion 4\'s arm walks these fields, and a '
              'field holding a different object of the right TYPE would pass '
              'the type arm while the plant ran two value sources');
      expect(identical(composed.freshness, freshness), isTrue,
          reason: 'and the sweep with it');
      expect(identical(composed.api.values, freshness), isTrue,
          reason: 'the adapter must READ through the supplied sweep. Surfacing '
              'it on the record while serving from another is the same defect '
              'wearing the test\'s clothes');

      expect(identical(pipe.onKeyRetired, retired), isTrue,
          reason: 'BackendLiveValues registers onKeyRetired in its '
              'constructor — "an obligation wired at a call site is an '
              'obligation that can be forgotten at a call site". A second '
              'BackendLiveValues against this pipe would have overwritten it, '
              'and IN-02\'s retraction would then be delivered to an object '
              'nothing reads');
      expect(identical(pipe.onWorkerDied, died), isTrue,
          reason: 'and BackendFreshnessSweep registers onWorkerDied. A second '
              'sweep silently wins the callback, so a worker\'s death degrades '
              'the keys of a value source nobody is serving from');
      expect(identical(pipe.onWorkerReady, ready), isTrue,
          reason: 'the resnapshot half of the same registration');
    });

    test('half a pair is refused by name, and the message says why', () {
      final pipe = PipeMainEndpoint();
      final keyMappings = _mappings();
      final values = BackendLiveValues(
        pipe: pipe,
        keyMappings: keyMappings,
        logger: Logger(level: Level.off),
      );

      // values without freshness: the composer would wrap a SECOND sweep round
      // the supplied live half, and that second sweep takes the pipe's
      // onWorkerDied off whichever sweep the caller is actually using.
      expect(
          () => compose(pipe: pipe, keyMappings: keyMappings, values: values),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message.toString(), 'message', contains('values'))
              .having((e) => e.message.toString(), 'message',
                  contains('freshness'))),
          reason: 'both parameter names must appear, so the message says what '
              'to pass rather than that something is wrong');

      // freshness without values: the record's `liveValues` would then be a
      // live half nothing wraps, sitting under a sweep built around a
      // different one. Two value sources for one plant.
      final orphanSweep = BackendFreshnessSweep(
        values: values,
        staleAfter: values.staleAfter,
        logger: Logger(level: Level.off),
      );
      expect(
          () => compose(
              pipe: pipe, keyMappings: keyMappings, freshness: orphanSweep),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message.toString(), 'message', contains('values'))
              .having((e) => e.message.toString(), 'message',
                  contains('freshness'))),
          reason: 'the other direction, and it is not symmetric decoration: a '
              'sweep wrapped around a live half the composition does not '
              'surface is the harder one to notice by reading');
    });

    test('supplying neither leaves the composition exactly as it was', () {
      // Every Phase 13 arm above runs through this path. The new parameters
      // must be additive, or this plan silently re-composes the backend.
      final composed = compose();

      expect(composed.liveValues, isA<BackendLiveValues>());
      expect(composed.freshness, isA<BackendFreshnessSweep>());
      expect(identical(composed.api.values, composed.freshness), isTrue,
          reason: 'the adapter reads through the sweep, never the live half');
      expect(composed.freshness.staleAfter, kBackendStaleAfter,
          reason: 'the default deadline is unchanged; the pair the composer '
              'builds for itself is the pair it always built');
    });
  });

  // ------------------------------------------------- the binary's own block

  group('bin/main.dart is the caller, and only the caller', () {
    late String main;

    setUpAll(() {
      main = _stripComments(File('bin/main.dart').readAsStringSync());
    });

    test('the scan actually reads the file it claims to', () {
      // An absence assertion that never matched anything passes for ever.
      // 13-06's Task 2 was written around exactly this hole.
      expect(main, contains('void main()'));
      expect(main, contains('pipe.addWorker('));
    });

    test('there is exactly ONE composition site', () {
      expect('composeBackendRelay('.allMatches(main).length, 1,
          reason: 'this is what makes the whole file above evidence about the '
              'BINARY rather than about a function the binary might call. Two '
              'composition sites is two object graphs, and the test would be '
              'assembling one of them while the plant ran the other.');
    });

    test('the boot line is printed on BOTH branches, outside the guard', () {
      expect(main, contains('bootLogLine'),
          reason: 'T-13-06-d: one clear line saying whether the WebSocket is '
              'on, every boot, configured or not');

      final guarded = _bodyOf(main, 'if (relayConfig != null)');
      expect(guarded, isNotEmpty,
          reason: 'the relay block must be guarded by a null check on the '
              'config, or a backend with no relay section does not boot');
      expect(guarded, isNot(contains('bootLogLine')),
          reason: 'a boot line inside the guard is a boot line the OFF case '
              'never prints, which is the silent-off failure 13-06 exists to '
              'prevent');
    });

    test('nothing starts a relay outside that guard', () {
      final guarded = _bodyOf(main, 'if (relayConfig != null)');
      expect(guarded, contains('composeBackendRelay('));
      expect(guarded, contains('.start()'),
          reason: 'compose allocates; start() binds. Both belong inside the '
              'guard — off means no socket, not a socket nobody uses');
    });

    test('the config-watch key set gained nothing', () {
      // The relay config lives in the stateman file, not in a preference row,
      // so a relay-config change is applied by restarting the process exactly
      // like a stateman change is today. No file watcher, no new key.
      final watcher = _statementAt(main, 'PreferencesWatcher.forDatabase');
      expect(watcher, contains("'key_mappings'"));
      expect(watcher, contains("'alarm_man_config'"));
      expect(watcher, isNot(contains('relay')),
          reason: 'restart-to-apply goes through the existing shutdown; a '
              'relay key here would be a second restart trigger for a value '
              'that is not in the database at all');
    });

    test('the shutdown path did not grow a teardown', () {
      // pipe_shutdown_structure_test.dart owns this property and has been shown
      // to bite four times (12-06 sabotages A-D). It is restated here because
      // this plan is the one that adds a closeable object to the process, and
      // the arm should fail in the file whose change caused it.
      //
      // What the path DID grow, deliberately, is the 4002 announcement (rig
      // probe P9). That is not a teardown: `announceDraining` queues a close
      // frame per socket and returns, releasing nothing and awaiting nothing,
      // and the arms below still forbid every shape that can block.
      final body = _bodyOf(main, 'void _shutdown(');
      expect(body, isNotEmpty);
      // The keyword, not the substring (13-14). `unawaited(…)` contains the
      // letters and means the exact opposite of awaiting — it is the marker
      // that says a call is deliberately not waited on. A scan that failed on
      // it would push the next person towards a bare fire-and-forget call with
      // no marker at all, which is the shape that is actually hard to review.
      // `\bawait\b` still catches every real await, `await for` included.
      expect(RegExp(r'\bawait\b').hasMatch(body), isFalse,
          reason: 'RelayServer.close() on this path is the 5.76 s stall '
              'coming back on the most common restart in the plant. The '
              'process is about to exit(0); the sockets go with it');
      expect(body, isNot(contains('close(')),
          reason: 'the drain ANNOUNCES; it must not close the server. '
              'RelayServer.close() awaits every session\'s peer');
      expect(main, isNot(contains('.close(')),
          reason: 'the whole file, not just the function: an async helper '
              'awaited from _shutdown would pass the arm above');
      expect(body, contains('announceDraining()'),
          reason: 'without it every planned restart is a 1006 the panel '
              'cannot tell from a broken network — which is what the rig '
              'measured');
    });

    // REPLACED BY 14-08, deliberately. What used to stand here required
    // `StateMan.create(`, `AlarmMan.create(` and `activeAlarms().listen(` to
    // still be PRESENT in bin/main.dart — a Phase 13 arm whose only job was to
    // stop the relay work "tidying away" a block that was not its to touch. It
    // was doing that job right up to this plan, which is the plan that deletes
    // the block on purpose (ALRM-01).
    //
    // The property is not dropped, it is INVERTED and moved to its owner:
    // `test/core/alarm_structure_test.dart` arms 1-3 require those same three
    // landmarks to be ABSENT, with the reason each one may not come back. So
    // the three strings are still pinned in exactly one place, and a reader
    // arriving at either file is pointed at the other.

    test('the hoisted value source is passed in, not built in here', () {
      // 14-08's half of P-5, measured at the call site rather than only inside
      // composeBackendRelay. The composer accepting a pair is worth nothing if
      // the binary never hands one over: it would build its own, and the pair
      // main built for the alarm engine would be a SECOND value source whose
      // registrations the composer's pair silently overwrote.
      final call = _statementAt(main, 'composeBackendRelay(');
      expect(call, isNotEmpty);
      expect(call, contains('values:'),
          reason: 'the live half main built before the relay guard must be the '
              'live half the relay serves from, or the process holds two');
      expect(call, contains('freshness:'),
          reason: 'and the sweep with it — half a pair is refused by the '
              'composer, which is what makes this arm a spelling check rather '
              'than a safety property on its own');
    });
  });
}

// ------------------------------------------------------------- source scanning
//
// Copied from `test/core/pipe_shutdown_structure_test.dart` rather than
// imported: its helpers are library-private, and the alternative — making them
// public so a second file can share them — would make the pin that has bitten
// four times editable from somewhere other than the pin. Three small functions
// are the cheaper duplication.

/// [source] with `//` line comments and `/* */` block comments removed.
String _stripComments(String source) {
  final out = StringBuffer();
  var inBlock = false;
  for (final rawLine in source.split('\n')) {
    var line = rawLine;
    if (inBlock) {
      final end = line.indexOf('*/');
      if (end < 0) {
        out.writeln();
        continue;
      }
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) {
      out.writeln();
      continue;
    }
    final comment = _lineCommentAt(line);
    if (comment >= 0) line = line.substring(0, comment);
    out.writeln(line);
  }
  return out.toString();
}

/// Where a real `//` comment starts on [line], or -1.
int _lineCommentAt(String line) {
  var singles = 0;
  var doubles = 0;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'") singles++;
    if (c == '"') doubles++;
    if (c == '/' && line[i + 1] == '/' && singles.isEven && doubles.isEven) {
      return i;
    }
  }
  return -1;
}

/// The brace-matched body of the construct whose declaration contains
/// [signature]. Empty when there is no such construct.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}

/// The whole statement beginning at [anchor], up to its terminating `;`.
String _statementAt(String source, String anchor) {
  final start = source.indexOf(anchor);
  if (start < 0) return '';
  final end = source.indexOf(';', start);
  return end < 0 ? source.substring(start) : source.substring(start, end + 1);
}
